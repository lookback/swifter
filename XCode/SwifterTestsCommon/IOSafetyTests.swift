//
//  IOSafetyTests.swift
//  Swifter
//
//  Created by Brian Gerstle on 8/20/16.
//  Copyright © 2016 Damian Kołakowski. All rights reserved.
//

import XCTest
import Swifter

class IOSafetyTests: XCTestCase {
    var server: HttpServer!

    override func setUp() {
        super.setUp()
        server = HttpServer.pingServer()
    }
    
    override func tearDown() {
        if server.operating {
            server.stop()
        }
        super.tearDown()
    }

    func testStopWithActiveConnections() {
        (0...100).forEach { _ in
            server = HttpServer.pingServer()
            try! server.start()
            XCTAssertFalse(NSURLSession.sharedSession().retryPing())
            (0...100).forEach { _ in
                dispatch_async(dispatch_get_global_queue(0, 0)) {
                    NSURLSession.sharedSession().pingTask { _, _, _ in }.resume()
                }
            }
            server.stop()
        }
    }
}
