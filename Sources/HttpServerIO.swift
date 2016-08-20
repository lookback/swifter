//
//  HttpServer.swift
//  Swifter
//
//  Copyright (c) 2014-2016 Damian Kołakowski. All rights reserved.
//

#if os(Linux)
    import Glibc
#else
    import Foundation
#endif

public class HttpServerIO {
    
    private var socket = Socket(socketFileDescriptor: -1)
    private var sockets = Set<Socket>()
    private var stateValue: Int32 = HttpServerIOState.Stopped.rawValue
    public private(set) var state: HttpServerIOState {
        get {
            return HttpServerIOState(rawValue: stateValue)!
        }
        set(state) {
            OSAtomicCompareAndSwapInt(self.state.rawValue, state.rawValue, &stateValue)
        }
    }
    public var operating: Bool { get { return self.state == .Running } }
    private let queue = dispatch_queue_create("swifter.httpserverio.clientsockets", DISPATCH_QUEUE_SERIAL)
    
    public func port() throws -> Int {
        return Int(try socket.port())
    }
    
    public func isIPv4() throws -> Bool {
        return try socket.isIPv4()
    }
    
    deinit {
        stop()
    }
    
    public func start(port: in_port_t = 8080, forceIPv4: Bool = false, priority: Int = DISPATCH_QUEUE_PRIORITY_BACKGROUND) throws {
        guard !self.operating else { return }
        stop()
        self.state = .Starting
        self.socket = try Socket.tcpSocketForListen(port, forceIPv4: forceIPv4)
        dispatch_async(dispatch_get_global_queue(priority, 0)) { [weak self] in
            guard let `self` = self else { return }
            guard self.operating else { return }
            while let socket = try? self.socket.acceptClientSocket() {
                dispatch_async(dispatch_get_global_queue(priority, 0), { [weak self] in
                    guard let `self` = self else { return }
                    guard self.operating else { return }
                    dispatch_async(self.queue) {
                        self.sockets.insert(socket)
                    }
                    self.handleConnection(socket)
                    dispatch_async(self.queue) {
                        self.sockets.remove(socket)
                    }
                })
            }
            self.stop()
        }
        self.state = .Running
    }
    
    public func stop() {
        guard self.operating else { return }
        self.state = .Stopping
        // Shutdown connected peers because they can live in 'keep-alive' or 'websocket' loops.
        for socket in self.sockets {
            socket.shutdwn()
        }
        dispatch_sync(queue) {
            self.sockets.removeAll(keepCapacity: true)
        }
        socket.release()
        self.state = .Stopped
    }
    
    public func dispatch(request: HttpRequest) -> ([String: String], HttpRequest -> HttpResponse) {
        return ([:], { _ in HttpResponse.NotFound })
    }
    
    private func handleConnection(socket: Socket) {
        let parser = HttpParser()
        while self.operating, let request = try? parser.readHttpRequest(socket) {
            let request = request
            request.address = try? socket.peername()
            let (params, handler) = self.dispatch(request)
            request.params = params
            let response = handler(request)
            var keepConnection = parser.supportsKeepAlive(request.headers)
            do {
                if self.operating {
                    keepConnection = try self.respond(socket, response: response, keepAlive: keepConnection)
                }
            } catch {
                print("Failed to send response: \(error)")
                break
            }
            if let session = response.socketSession() {
                session(socket)
                break
            }
            if !keepConnection { break }
        }
        socket.release()
    }
    
    private struct InnerWriteContext: HttpResponseBodyWriter {
        
        let socket: Socket

        func write(file: File) throws {
            try socket.writeFile(file)
        }

        func write(data: [UInt8]) throws {
            try write(ArraySlice(data))
        }

        func write(data: ArraySlice<UInt8>) throws {
            try socket.writeUInt8(data)
        }
    }
    
    private func respond(socket: Socket, response: HttpResponse, keepAlive: Bool) throws -> Bool {
        guard self.operating else { return false }

        try socket.writeUTF8("HTTP/1.1 \(response.statusCode()) \(response.reasonPhrase())\r\n")
        
        let content = response.content()
        
        if content.length >= 0 {
            try socket.writeUTF8("Content-Length: \(content.length)\r\n")
        }
        
        if keepAlive && content.length != -1 {
            try socket.writeUTF8("Connection: keep-alive\r\n")
        }
        
        for (name, value) in response.headers() {
            try socket.writeUTF8("\(name): \(value)\r\n")
        }
        
        try socket.writeUTF8("\r\n")
    
        if let writeClosure = content.write {
            let context = InnerWriteContext(socket: socket)
            try writeClosure(context)
        }
        
        return keepAlive && content.length != -1;
    }
}

public enum HttpServerIOState: Int32 {
    case Starting
    case Running
    case Stopping
    case Stopped
}

#if os(Linux)
    
let DISPATCH_QUEUE_PRIORITY_BACKGROUND = 0

private class dispatch_context {
    let block: ((Void) -> Void)
    init(_ block: ((Void) -> Void)) {
        self.block = block
    }
}

func dispatch_get_global_queue(queueId: Int, _ arg: Int) -> Int { return 0 }

func dispatch_async(queueId: Int, _ block: ((Void) -> Void)) {
    let unmanagedDispatchContext = Unmanaged.passRetained(dispatch_context(block))
    let context = UnsafeMutablePointer<Void>(unmanagedDispatchContext.toOpaque())
    var pthread: pthread_t = 0
    pthread_create(&pthread, nil, { (context: UnsafeMutablePointer<Void>) -> UnsafeMutablePointer<Void> in
        let unmanaged = Unmanaged<dispatch_context>.fromOpaque(COpaquePointer(context))
        unmanaged.takeUnretainedValue().block()
        unmanaged.release()
        return context
    }, context)
}
    
#endif

