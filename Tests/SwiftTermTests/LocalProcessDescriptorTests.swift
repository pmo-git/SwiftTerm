#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import SwiftTerm

final class LocalProcessDescriptorTests: XCTestCase {
    private final class Session: LocalProcessDelegate {
        let queue = DispatchQueue(label: "LocalProcessDescriptorTests.delegate")
        let lock = NSLock()
        var output = ""
        var exits: [Int32?] = []
        lazy var process = LocalProcess(delegate: self, dispatchQueue: queue)

        func dataReceived(slice: ArraySlice<UInt8>) {
            lock.lock()
            output += String(decoding: slice, as: UTF8.self)
            lock.unlock()
        }
        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            lock.lock()
            exits.append(exitCode)
            lock.unlock()
        }
        func getWindowSize() -> winsize {
            winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        }
        var transcript: String {
            lock.lock()
            defer { lock.unlock() }
            return output
        }
        func contains(_ text: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return output.contains(text)
        }
        var exitCodes: [Int32?] {
            lock.lock()
            defer { lock.unlock() }
            return exits
        }
        func start(_ script: String, arguments: [String] = []) {
            queue.sync {
                process.startProcess(executable: "/bin/sh", args: ["-c", script, "pty-test"] + arguments)
            }
        }
        func send(_ text: String) {
            queue.sync { process.send(data: Array(text.utf8)[...]) }
        }
        func stop() {
            // Keep the production exit monitor responsible for reaping the child.
            let pid = queue.sync { process.shellPid }
            if pid > 0 && exitCodes.isEmpty {
                _ = kill(pid, SIGKILL)
                _ = eventually { !self.exitCodes.isEmpty }
            }
            queue.sync { process.terminate() }
        }
    }

    private static func eventually(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        return predicate()
    }

    private let echoLoop = "while IFS= read -r line; do printf 'reply:%s\\n' \"$line\"; done"

    // fstat alone cannot identify a Darwin PTY: all /dev/ptmx masters can
    // have the same device/inode. ptsname identifies the associated slave.
    private func identity(_ fd: Int32) throws -> String {
        String(cString: try XCTUnwrap(ptsname(fd)))
    }

    private func makeProbe() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("probe.c")
        let binary = directory.appendingPathComponent("probe")
        // Enumerate every descriptor, including a possible different FD number.
        // The probe deliberately leaves inherited descriptors untouched.
        try """
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <unistd.h>
        int main(int argc, char **argv) {
            if (argc < 2) return 2;
            if (strcmp(argv[1], "eof") == 0) {
                char line[32];
                puts("ready-EOF");
                fflush(stdout);
                if (!fgets(line, sizeof(line), stdin)) return 3;
                close(0); close(1); close(2);
                if (argc != 3) return 4;
                FILE *marker = fopen(argv[2], "w");
                if (!marker) return 5;
                fclose(marker);
                sleep(30);
                return 0;
            }
            int inherited = 0;
            for (int fd = 0; fd < getdtablesize(); fd++) {
                char *name = ptsname(fd);
                if (name && strcmp(name, argv[1]) == 0) inherited++;
            }
            printf("inherited=%d\\n", inherited);
            fflush(stdout);
            return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [source.path, "-o", binary.path]
        try compiler.run()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0, "The real-exec identity probe must compile")
        return binary
    }

    func testLaterShellCannotAccessEarlierMasterAndBothExchangeIO() throws {
        let probe = try makeProbe()
        let a = Session(), b = Session()
        defer { b.stop(); a.stop() }
        a.start("printf 'ready-A\\n'; " + echoLoop)
        XCTAssertTrue(Self.eventually { a.contains("ready-A") })
        let fd = a.process.childfd
        let slave = try identity(fd)
        XCTAssertEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, FD_CLOEXEC)

        b.start("\"$1\" \"$2\"; printf 'ready-B\\n'; " + echoLoop,
                arguments: [probe.path, slave])
        XCTAssertTrue(Self.eventually { b.contains("ready-B") })
        XCTAssertTrue(b.contains("inherited=0"), "B inherited A's PTY master: \(b.transcript)")
        var size = winsize(ws_row: 31, ws_col: 97, ws_xpixel: 0, ws_ypixel: 0)
        XCTAssertEqual(PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: fd, windowSize: &size), 0)
        var actual = winsize()
        XCTAssertEqual(ioctl(fd, TIOCGWINSZ, &actual), 0)
        XCTAssertEqual(actual.ws_row, 31)
        XCTAssertEqual(actual.ws_col, 97)
        a.send("only-A\n")
        b.send("only-B\n")
        XCTAssertTrue(Self.eventually { a.contains("reply:only-A") && b.contains("reply:only-B") })
        XCTAssertFalse(a.contains("only-B"))
        XCTAssertFalse(b.contains("only-A"))
    }

    func testEarlyEOFCallbackStillProtectsDispatchIOOwnedMaster() throws {
        let probe = try makeProbe()
        let a = Session(), b = Session()
        defer { b.stop(); a.stop() }
        let closed = probe.deletingLastPathComponent().appendingPathComponent("streams-closed")
        a.start("exec \"$1\" eof \"$2\"", arguments: [probe.path, closed.path])
        XCTAssertTrue(Self.eventually { a.contains("ready-EOF") })
        let fd = a.process.childfd
        let slave = try identity(fd)
        a.send("close\n")
        XCTAssertTrue(Self.eventually { FileManager.default.fileExists(atPath: closed.path) })
        // Closing the real slave streams does not reliably produce a non-nil
        // empty DispatchData on every Darwin DispatchIO version. Deliver that
        // EOF callback shape explicitly to exercise the production marker reset.
        a.process.readQueue.sync {
            a.process.childProcessRead(done: true, data: DispatchData.empty, errno: 0)
            XCTAssertEqual(a.process.childfd, -1)
        }
        XCTAssertTrue(a.exitCodes.isEmpty, "EOF must precede process exit")
        XCTAssertGreaterThanOrEqual(fcntl(fd, F_GETFD), 0, "DispatchIO still owns the original master")
        XCTAssertEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, FD_CLOEXEC)
        b.start("\"$1\" \"$2\"; printf 'ready-B\\n'; " + echoLoop,
                arguments: [probe.path, slave])
        XCTAssertTrue(Self.eventually { b.contains("ready-B") })
        XCTAssertTrue(b.contains("inherited=0"), "EOF hid an inheritable master: \(b.transcript)")
        b.send("after-EOF\n")
        XCTAssertTrue(Self.eventually { b.contains("reply:after-EOF") })
        a.stop()
        XCTAssertTrue(Self.eventually { fcntl(fd, F_GETFD) == -1 && errno == EBADF })
    }

    func testInterruptedProtectionRetriesBothCommandsAndPreservesFlags() {
        let session = Session()
        defer { session.stop() }
        var calls: [Int32] = []
        let extraFlag: Int32 = 0x40 // Model a flag unknown to this implementation.
        session.process.masterDescriptorControl = { [unowned session] fd, command, value in
            XCTAssertFalse(session.process.running)
            XCTAssertEqual(session.process.childfd, -1)
            XCTAssertEqual(session.process.shellPid, 0)
            XCTAssertNil(session.process.io)
            XCTAssertNil(session.process.childMonitor)
            let firstAttempt = !calls.contains(command)
            calls.append(command)
            if firstAttempt {
                errno = EINTR
                return -1
            }
            if command == F_GETFD {
                return fcntl(fd, command) | extraFlag
            }
            XCTAssertEqual(value, extraFlag | FD_CLOEXEC)
            // The synthetic extra flag only exists in this controlled seam.
            return fcntl(fd, command, value & ~extraFlag)
        }
        session.start("printf 'ready-retry\\n'; " + echoLoop)
        XCTAssertEqual(calls, [F_GETFD, F_GETFD, F_SETFD, F_SETFD])
        XCTAssertTrue(Self.eventually { session.contains("ready-retry") })
        XCTAssertEqual(fcntl(session.process.childfd, F_GETFD) & FD_CLOEXEC, FD_CLOEXEC)
        session.send("after-retry\n")
        XCTAssertTrue(Self.eventually { session.contains("reply:after-retry") })
    }

    func testProtectionFailureClosesPrivateMasterKillsAndReapsChild() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for failingCommand in [F_GETFD, F_SETFD] {
            let session = Session()
            let pidFile = directory.appendingPathComponent("pid-\(failingCommand)")
            var privateFD: Int32 = -1
            var childPID: pid_t?
            session.process.masterDescriptorControl = { fd, command, value in
                privateFD = fd
                if command == failingCommand {
                    // Ensure the actual child is running and ignores HUP/TERM
                    // before the launch is rejected. No descendant is spawned.
                    XCTAssertTrue(Self.eventually {
                        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
                              let pid = pid_t(text), pid > 0 else { return false }
                        childPID = pid
                        return true
                    })
                    errno = EIO
                    return -1
                }
                return fcntl(fd, command, value)
            }
            session.start("trap '' HUP TERM; printf '%s' \"$$\" > \"$1\"; while :; do :; done",
                          arguments: [pidFile.path])
            XCTAssertFalse(session.process.running)
            XCTAssertEqual(session.process.childfd, -1)
            XCTAssertEqual(session.process.shellPid, 0)
            XCTAssertNil(session.process.io)
            XCTAssertNil(session.process.childMonitor)
            XCTAssertEqual(session.exitCodes.count, 1)
            XCTAssertNil(session.exitCodes.first ?? nil, "The delegate must receive launch failure")
            XCTAssertGreaterThanOrEqual(privateFD, 0)
            XCTAssertEqual(fcntl(privateFD, F_GETFD), -1)
            XCTAssertEqual(errno, EBADF)
            let pid = try XCTUnwrap(childPID)
            var status: Int32 = 0
            XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
            XCTAssertEqual(errno, ECHILD, "The rejected child must already have been reaped")
            XCTAssertEqual(kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
    }

    func testFastShellExitStillDeliversStatusAndReapsChild() {
        let session = Session()
        defer { session.stop() }
        session.start("exit 7")
        XCTAssertTrue(Self.eventually { session.exitCodes.count == 1 })
        XCTAssertEqual(session.exitCodes.first ?? nil, 7 << 8)
        let pid = session.queue.sync { () -> pid_t in
            XCTAssertFalse(session.process.running)
            return session.process.shellPid
        }
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }
}
#endif
