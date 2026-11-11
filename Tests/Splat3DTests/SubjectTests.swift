import XCTest
@testable import Splat3D

// MARK: - Object scan tests
//
// A subject is one moment in the video and 1 to 5 points on one object. It is
// checked when it is made, so a bad one never reaches a request, and create
// sends it as `{"subject": {"time_s": ..., "points": [[x, y], ...]}}`.

extension SplatClientTests {

    /// 403 from createScene while object scans are off (api/src/lib/scenes.ts
    /// in gaussian-splatting PR #525).
    private static let featureDisabled = Fixture.error("feature_disabled", "Object scans are not available.")

    /// The docs' example: two points, 12.4 s in.
    private func makeSubject() throws -> SceneSubject {
        try SceneSubject(
            timeSeconds: 12.4,
            points: [CGPoint(x: 0.52, y: 0.61), CGPoint(x: 0.5, y: 0.7)]
        )
    }

    /// The `subject` of a captured create request, or `nil` when it has none.
    private func sentSubject() throws -> [String: Any]? {
        let body = try jsonBody(MockURLProtocol.requests(to: "/v1/scenes").first)
        return body["subject"] as? [String: Any]
    }

    // MARK: - Encoding

    func testCreateSceneSendsTheSubject() async throws {
        MockURLProtocol.stub("/v1/scenes", .json(201, Fixture.createScene))

        _ = try await makeClient().createScene(subject: try makeSubject())

        let subject = try XCTUnwrap(try sentSubject())
        XCTAssertEqual(Set(subject.keys), ["time_s", "points"])
        XCTAssertEqual(subject["time_s"] as? Double, 12.4)
        XCTAssertEqual(subject["points"] as? [[Double]], [[0.52, 0.61], [0.5, 0.7]])
    }

    func testCreateSceneOmitsAnAbsentSubject() async throws {
        MockURLProtocol.stub("/v1/scenes", .json(201, Fixture.createScene))

        _ = try await makeClient().createScene(title: "Kitchen")

        let body = try jsonBody(MockURLProtocol.requests(to: "/v1/scenes").first)
        XCTAssertNil(body["subject"])
    }

    func testCreateAndProcessSendsTheSubject() async throws {
        stubCreateAndUpload()
        MockURLProtocol.stub("\(Fixture.scenePath)/process", .json(200, Fixture.processAccepted))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.completeScene))

        _ = try await makeClient().createAndProcess(videoURL: try makeVideo(), subject: try makeSubject())

        let subject = try XCTUnwrap(try sentSubject())
        XCTAssertEqual(subject["time_s"] as? Double, 12.4)
        XCTAssertEqual(subject["points"] as? [[Double]], [[0.52, 0.61], [0.5, 0.7]])

        // The launch is unchanged: the scene carries the subject.
        let launch = try jsonBody(MockURLProtocol.requests(to: "\(Fixture.scenePath)/process").first)
        XCTAssertNil(launch["subject"])
    }

    // MARK: - Validation

    func testSubjectTakesOneToFivePoints() throws {
        let corner = CGPoint(x: 0, y: 1)

        for count in [1, 5] {
            let subject = try SceneSubject(timeSeconds: 0, points: Array(repeating: corner, count: count))
            XCTAssertEqual(subject.points.count, count)
        }
        for count in [0, 6] {
            XCTAssertThrowsError(try SceneSubject(timeSeconds: 0, points: Array(repeating: corner, count: count))) { error in
                XCTAssertEqual(error as? SceneSubject.Invalid, .pointCount(count))
            }
        }
    }

    func testSubjectRefusesPointsOutsideTheFrame() {
        let outside = [
            CGPoint(x: -0.01, y: 0.5),
            CGPoint(x: 1.01, y: 0.5),
            CGPoint(x: 0.5, y: -0.01),
            CGPoint(x: 0.5, y: 1.01),
        ]

        for point in outside {
            XCTAssertThrowsError(try SceneSubject(timeSeconds: 0, points: [CGPoint(x: 0.5, y: 0.5), point])) { error in
                XCTAssertEqual(error as? SceneSubject.Invalid, .coordinate(point))
            }
        }
        XCTAssertThrowsError(try SceneSubject(timeSeconds: 0, points: [CGPoint(x: CGFloat.nan, y: 0.5)]))
    }

    func testSubjectRefusesATimeBeforeTheStart() {
        let times: [TimeInterval] = [-0.1, .infinity, .nan]

        for time in times {
            XCTAssertThrowsError(try SceneSubject(timeSeconds: time, points: [CGPoint(x: 0.5, y: 0.5)]), "\(time)")
        }
        XCTAssertThrowsError(try SceneSubject(timeSeconds: -0.1, points: [CGPoint(x: 0.5, y: 0.5)])) { error in
            XCTAssertEqual(error as? SceneSubject.Invalid, .time(-0.1))
        }
    }

    func testInvalidSubjectSaysWhatIsWrong() {
        XCTAssertEqual(
            SceneSubject.Invalid.pointCount(6).errorDescription,
            "A subject takes 1 to 5 points, not 6."
        )
        XCTAssertEqual(
            SceneSubject.Invalid.coordinate(CGPoint(x: 1.5, y: 0.5)).errorDescription,
            "A subject's points are fractions of the frame, from 0 to 1, not (1.5, 0.5)."
        )
        XCTAssertEqual(
            SceneSubject.Invalid.time(-2).errorDescription,
            "A subject's time is 0 seconds or more into the video, not -2.0."
        )
    }

    /// A bad subject can't be made, so nothing is sent for one.
    func testInvalidSubjectSendsNothing() async {
        do {
            _ = try await makeClient().createScene(subject: try SceneSubject(timeSeconds: 0, points: []))
            XCTFail("Expected SceneSubject.Invalid")
        } catch {
            XCTAssertEqual(error as? SceneSubject.Invalid, .pointCount(0))
        }

        XCTAssertTrue(MockURLProtocol.capturedRequests.isEmpty)
    }

    // MARK: - Object scans switched off

    func testFeatureDisabledIsRecognizable() async throws {
        MockURLProtocol.stub("/v1/scenes", .json(403, Self.featureDisabled))
        let subject = try makeSubject()

        let error = await expectSplatError { try await self.makeClient().createScene(subject: subject) }

        guard case .requestFailed(let apiError) = error else {
            return XCTFail("Expected .requestFailed, got \(String(describing: error))")
        }
        XCTAssertEqual(apiError.statusCode, 403)
        XCTAssertEqual(apiError.code, "feature_disabled")
        XCTAssertEqual(apiError.message, "Object scans are not available.")
        XCTAssertEqual(apiError.requestID, Fixture.requestID)
    }

    /// createAndProcess throws it as it is, not as an interruption: no scene
    /// exists, so there is nothing to resume.
    func testCreateAndProcessThrowsFeatureDisabledAsIs() async throws {
        MockURLProtocol.stub("/v1/scenes", .json(403, Self.featureDisabled))
        let video = try makeVideo()
        let subject = try makeSubject()

        let error = await expectSplatError {
            try await self.makeClient().createAndProcess(videoURL: video, subject: subject)
        }

        guard case .requestFailed(let apiError) = error else {
            return XCTFail("Expected .requestFailed, got \(String(describing: error))")
        }
        XCTAssertEqual(apiError.code, "feature_disabled")
        XCTAssertTrue(MockURLProtocol.requests(to: "/upload").isEmpty)
    }
}
