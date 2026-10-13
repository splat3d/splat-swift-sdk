import XCTest
@testable import Splat3D

// MARK: - Scene model decoding
//
// Payloads mirror what GET /v1/scenes/{id} returns today (api/src/lib/scenes.ts
// in the gaussian-splatting repo): complete scenes carry viewer_url,
// download_url and format; in-flight scenes may report "preview_ready".

extension SplatClientTests {

    /// A scene payload with the given status and extra JSON fields.
    func scenePayload(id: String, status: String, extra: String = "") -> Data {
        let fields = extra.isEmpty ? "" : ",\n\(extra)"
        return mockJSON("""
        {
            "data": {
                "id": "\(id)",
                "title": null,
                "address": null,
                "status": "\(status)",
                "is_public": false,
                "processing_stage": null,
                "processing_pct": null,
                "num_gaussians": null,
                "thumbnail_r2_key": null,
                "created_at": "2026-09-28T12:00:00Z",
                "updated_at": "2026-09-28T12:00:00Z"\(fields)
            },
            "meta": { "request_id": "req-\(id)" }
        }
        """)
    }

    func testServerViewerURLWins() async throws {
        let extra = """
            "viewer_url": "https://splat-3d.com/tour/server-url",
            "download_url": "https://api.splat-3d.com/v1/scenes/server-url/download",
            "format": "sog"
        """
        MockURLProtocol.mockResponses["/v1/scenes/server-url"] =
            (200, scenePayload(id: "server-url", status: "complete", extra: extra))

        let scene = try await makeClient().getScene(id: "server-url")

        XCTAssertEqual(scene.viewerURL?.absoluteString, "https://splat-3d.com/tour/server-url")
        XCTAssertEqual(scene.downloadURL?.absoluteString, "https://api.splat-3d.com/v1/scenes/server-url/download")
        XCTAssertEqual(scene.format, .sog)
    }

    func testFallbackViewerURLUsesTourRoute() async throws {
        // /s/{id} was retired; it now returns 404 on splat-3d.com.
        let scene = SplatScene(id: "local", status: .complete)
        XCTAssertEqual(scene.viewerURL?.absoluteString, "https://splat-3d.com/tour/local")
    }

    func testANullViewerURLIsKept() async throws {
        // The API sends viewer_url null when a scene has no model to show,
        // even once it is complete (toPublicScene in api/src/lib/scenes.ts).
        MockURLProtocol.mockResponses["/v1/scenes/no-model"] =
            (200, scenePayload(id: "no-model", status: "complete", extra: "\"viewer_url\": null"))

        let scene = try await makeClient().getScene(id: "no-model")

        XCTAssertNil(scene.viewerURL)
    }

    func testEncodingKeepsANullViewerURL() throws {
        let json = """
            {"id": "no-model", "status": "complete", "is_public": false, "viewer_url": null,
             "created_at": "2026-09-28T12:00:00Z", "updated_at": "2026-09-28T12:00:00Z"}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let scene = try decoder.decode(SplatScene.self, from: Data(json.utf8))
        let again = try decoder.decode(SplatScene.self, from: encoder.encode(scene))

        XCTAssertNil(again.viewerURL)
    }

    func testPreviewReadyIsInProgress() async throws {
        MockURLProtocol.mockResponses["/v1/scenes/preview"] =
            (200, scenePayload(id: "preview", status: "preview_ready"))

        let scene = try await makeClient().getScene(id: "preview")

        XCTAssertEqual(scene.status, .previewReady)
        XCTAssertEqual(scene.status.rawValue, "preview_ready")
        XCTAssertTrue(scene.isProcessing)
    }

    func testUnknownStatusDecodesInsteadOfThrowing() async throws {
        MockURLProtocol.mockResponses["/v1/scenes/future"] =
            (200, scenePayload(id: "future", status: "some_future_state"))

        let scene = try await makeClient().getScene(id: "future")

        XCTAssertEqual(scene.status, SceneStatus(rawValue: "some_future_state"))
        XCTAssertEqual(scene.status.rawValue, "some_future_state")
    }

    func testFailedSceneCarriesProcessingError() async throws {
        let extra = #""processing_error": "Not enough overlap between photos""#
        MockURLProtocol.mockResponses["/v1/scenes/failed-scene"] =
            (200, scenePayload(id: "failed-scene", status: "failed", extra: extra))

        let scene = try await makeClient().getScene(id: "failed-scene")

        XCTAssertTrue(scene.isFailed)
        XCTAssertEqual(scene.processingError, "Not enough overlap between photos")
    }
}

// MARK: - Server statuses
//
// Every value the API can put in `status`: the database's tour_stage enum
// (supabase/migrations: create_tours, add_cancelled_stage, add_preview_fields,
// tour_stage_enum_additions in the gaussian-splatting repo), plus
// "processing", which APIs before 1.1.0 reported from getSceneStatus's live
// Modal probe. Since 1.1.0 every call returns the stored database value.

extension SplatClientTests {

    static let inFlightStatuses = [
        "uploading",
        "preview_extracting",
        "preview_generating",
        "preview_compressing",
        "preview_ready",
        "extracting_frames",
        "running_sfm",
        "estimating_poses",
        "training",
        "exporting",
        "compressing",
        "processing",
    ]

    static let terminalStatuses = ["complete", "failed", "cancelled"]

    /// Decode a scene whose `status` is `raw`.
    func scene(withStatus raw: String) async throws -> SplatScene {
        MockURLProtocol.mockResponses["/v1/scenes/status-\(raw)"] =
            (200, scenePayload(id: "status-\(raw)", status: raw))
        return try await makeClient().getScene(id: "status-\(raw)")
    }

    func testEveryInFlightServerStatusIsProcessing() async throws {
        for raw in Self.inFlightStatuses {
            let scene = try await scene(withStatus: raw)

            XCTAssertEqual(scene.status.rawValue, raw)
            XCTAssertTrue(scene.isProcessing, "\(raw) is in flight")
        }
    }

    func testTerminalServerStatusesAreNotProcessing() async throws {
        for raw in Self.terminalStatuses {
            let scene = try await scene(withStatus: raw)

            XCTAssertFalse(scene.isProcessing, "\(raw) is terminal")
        }
    }

    func testEveryServerStatusHasAName() {
        let named = Set(SceneStatus.allCases.map(\.rawValue))

        XCTAssertEqual(named, Set(Self.inFlightStatuses + Self.terminalStatuses))
    }

    func testFutureStatusCountsAsProcessing() async throws {
        // Anything that isn't terminal is still in flight, even a stage this
        // SDK has never heard of.
        let scene = try await scene(withStatus: "some_future_stage")

        XCTAssertTrue(scene.isProcessing)
    }
}

// MARK: - Thumbnail URL

extension SplatClientTests {

    func testThumbnailURLUsesTheClientsBaseURL() async throws {
        // A client pointed at another deployment must not link thumbnails
        // to production, where that scene ID doesn't exist.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let staging = try XCTUnwrap(URL(string: "https://api-staging.example.com"))
        let client = SplatClient(apiKey: "s3d_test_key_12345", baseURL: staging, session: URLSession(configuration: config))
        MockURLProtocol.mockResponses["/v1/scenes/thumb"] = (200, mockJSON("""
        {
            "data": {
                "id": "thumb",
                "title": null,
                "address": null,
                "status": "complete",
                "is_public": false,
                "processing_stage": null,
                "processing_pct": 100,
                "num_gaussians": null,
                "thumbnail_r2_key": "tours/thumb/thumbnail.png",
                "created_at": "2026-09-28T12:00:00Z",
                "updated_at": "2026-09-28T12:00:00Z"
            },
            "meta": { "request_id": "req-thumb" }
        }
        """))

        let scene = try await client.getScene(id: "thumb")

        XCTAssertEqual(scene.thumbnailURL?.absoluteString, "https://api-staging.example.com/v1/scenes/thumb/thumbnail")
    }

    /// A complete scene with the given thumbnail keys, read by a client on
    /// `https://api-staging.example.com`.
    func stagingScene(id: String, thumbnailR2Key: String?, thumbnailURL: String?) async throws -> SplatScene {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let staging = try XCTUnwrap(URL(string: "https://api-staging.example.com"))
        let client = SplatClient(apiKey: "s3d_test_key_12345", baseURL: staging, session: URLSession(configuration: config))

        // A JSON string literal, or null.
        func literal(_ value: String?) -> String {
            value.map { "\"\($0)\"" } ?? "null"
        }
        MockURLProtocol.stub("/v1/scenes/\(id)", .json(200, """
        {
            "data": {
                "id": "\(id)",
                "title": null,
                "address": null,
                "status": "complete",
                "is_public": false,
                "processing_stage": null,
                "processing_pct": null,
                "num_gaussians": null,
                "thumbnail_r2_key": \(literal(thumbnailR2Key)),
                "thumbnail_url": \(literal(thumbnailURL)),
                "created_at": "\(Fixture.createdAt)",
                "updated_at": "\(Fixture.updatedAt)"
            },
            "meta": { "request_id": "\(Fixture.requestID)" }
        }
        """))

        return try await client.getScene(id: id)
    }

    func testThumbnailURLAloneMakesALink() async throws {
        // thumbnail_url is the documented field; thumbnail_r2_key is a
        // storage key an API may stop sending.
        let scene = try await stagingScene(
            id: "url-only",
            thumbnailR2Key: nil,
            thumbnailURL: "https://api-staging.example.com/v1/scenes/url-only/thumbnail"
        )

        XCTAssertEqual(scene.thumbnailURL?.absoluteString, "https://api-staging.example.com/v1/scenes/url-only/thumbnail")
    }

    func testAnAbsoluteThumbnailURLWins() async throws {
        // The API sends `<API_BASE_URL>/v1/scenes/<id>/thumbnail`
        // (toPublicScene in api/src/lib/scenes.ts): the server's answer.
        let scene = try await stagingScene(
            id: "absolute",
            thumbnailR2Key: "tours/absolute/thumbnail.png",
            thumbnailURL: "https://thumbs.example.com/v1/scenes/absolute/thumbnail"
        )

        XCTAssertEqual(scene.thumbnailURL?.absoluteString, "https://thumbs.example.com/v1/scenes/absolute/thumbnail")
    }

    func testARelativeThumbnailURLUsesTheClientsBaseURL() async throws {
        let scene = try await stagingScene(
            id: "relative",
            thumbnailR2Key: nil,
            thumbnailURL: "/v1/scenes/relative/thumbnail"
        )

        XCTAssertEqual(scene.thumbnailURL?.absoluteString, "https://api-staging.example.com/v1/scenes/relative/thumbnail")
    }

    func testNoThumbnailKeysMeansNoThumbnailURL() async throws {
        let scene = try await stagingScene(id: "none", thumbnailR2Key: nil, thumbnailURL: nil)

        XCTAssertNil(scene.thumbnailURL)
    }

    func testEncodingKeepsTheServersThumbnailURL() throws {
        // Decoded outside SplatClient, a scene would otherwise point its
        // thumbnail at production.
        let json = """
            {"id": "staged", "status": "complete", "is_public": false, "thumbnail_r2_key": null,
             "thumbnail_url": "https://api-staging.example.com/v1/scenes/staged/thumbnail",
             "created_at": "2026-09-28T12:00:00Z", "updated_at": "2026-09-28T12:00:00Z"}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let scene = try decoder.decode(SplatScene.self, from: Data(json.utf8))
        let again = try decoder.decode(SplatScene.self, from: encoder.encode(scene))

        XCTAssertEqual(again.thumbnailURL?.absoluteString, "https://api-staging.example.com/v1/scenes/staged/thumbnail")
    }
}

// MARK: - Scene details (API 1.5.0)
//
// preset, psnr, training_time_seconds, the processing stamps and the model
// sizes, from gaussian-splatting PR #450 (toPublicScene in
// api/src/lib/scenes.ts). Older APIs leave the keys out, and the API sends
// null where a scene has no value, so both must read nil.

extension SplatClientTests {

    /// The preset names API 1.5.0 can send: PRESET_NAMES in
    /// packages/core/src/params.ts, the enum of sceneSchema's `preset`.
    static let apiPresets = ["fast", "standard", "quality", "ultra", "custom"]

    /// Decode `body` as the answer to GET /v1/scenes/{id}.
    func scene(from body: String) async throws -> SplatScene {
        MockURLProtocol.stub(Fixture.scenePath, .json(200, body))
        return try await makeClient().getScene(id: Fixture.sceneID)
    }

    func testCompleteSceneCarriesItsDetails() async throws {
        let scene = try await scene(from: Fixture.completeSceneWithDetails)
        let expectedStart = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-28T12:01:00Z"))
        let startedAt = try XCTUnwrap(scene.processingStartedAt)
        let completedAt = try XCTUnwrap(scene.processingCompletedAt)

        XCTAssertEqual(scene.preset, .standard)
        XCTAssertEqual(scene.psnr, 26.1)
        XCTAssertEqual(scene.trainingTime, 233.7)
        XCTAssertEqual(startedAt.timeIntervalSince(expectedStart), 0, accuracy: 0.001)
        // 12:01:00 to 12:10:46.
        XCTAssertEqual(completedAt.timeIntervalSince(startedAt), 586, accuracy: 0.001)
        XCTAssertEqual(scene.modelSizes, SplatScene.ModelSizes(spz: 21_000_000, sog: 48_000_000, ply: 460_000_000))
        XCTAssertEqual(scene.format, .spz)
    }

    func testOlderAPIsLeaveTheDetailsNil() async throws {
        // API 1.3.0's answer, without any of the keys.
        let scene = try await scene(from: Fixture.completeScene)

        XCTAssertTrue(scene.isComplete)
        XCTAssertNil(scene.preset)
        XCTAssertNil(scene.psnr)
        XCTAssertNil(scene.trainingTime)
        XCTAssertNil(scene.processingStartedAt)
        XCTAssertNil(scene.processingCompletedAt)
        XCTAssertEqual(scene.modelSizes, SplatScene.ModelSizes())
    }

    func testNullDetailsReadNil() async throws {
        let scene = try await scene(from: Fixture.completeSceneWithNullDetails)

        XCTAssertTrue(scene.isComplete)
        XCTAssertNil(scene.preset)
        XCTAssertNil(scene.psnr)
        XCTAssertNil(scene.trainingTime)
        XCTAssertNil(scene.processingStartedAt)
        XCTAssertNil(scene.processingCompletedAt)
        XCTAssertNil(scene.modelSizes.spz)
        XCTAssertNil(scene.modelSizes.sog)
        XCTAssertNil(scene.modelSizes.ply)
    }

    func testUnknownPresetDecodesInsteadOfThrowing() async throws {
        let scene = try await scene(from: Fixture.completeScene(preset: "cinematic"))

        XCTAssertEqual(scene.preset, SplatScene.Preset(rawValue: "cinematic"))
        XCTAssertEqual(scene.preset?.description, "cinematic")
        XCTAssertEqual(scene.trainingTime, 233.7)
    }

    func testEveryAPIPresetHasAName() async throws {
        for raw in Self.apiPresets {
            let scene = try await scene(from: Fixture.completeScene(preset: raw))

            XCTAssertEqual(scene.preset?.rawValue, raw)
        }
        XCTAssertEqual(SplatScene.Preset.allCases.map(\.rawValue), Self.apiPresets)
    }

    func testCustomHasNoScenePreset() {
        // Retrain refuses custom, so ScenePreset, which retrain takes, lacks it.
        XCTAssertNil(ScenePreset(rawValue: SplatScene.Preset.custom.rawValue))
        XCTAssertEqual(ScenePreset(rawValue: SplatScene.Preset.quality.rawValue), .quality)
    }

    func testEncodingKeepsTheDetails() async throws {
        let scene = try await scene(from: Fixture.completeSceneWithDetails)

        let again = try JSONDecoder().decode(SplatScene.self, from: JSONEncoder().encode(scene))

        XCTAssertEqual(again, scene)
        XCTAssertEqual(again.preset, .standard)
        XCTAssertEqual(again.modelSizes.ply, 460_000_000)
    }

    func testDetailsTakePartInEquality() {
        let plain = SplatScene(id: "local", status: .complete, createdAt: .distantPast, updatedAt: .distantPast)
        let detailed = SplatScene(
            id: "local",
            status: .complete,
            createdAt: .distantPast,
            updatedAt: .distantPast,
            preset: .ultra,
            psnr: 27.5,
            trainingTime: 1_800,
            processingStartedAt: .distantPast,
            processingCompletedAt: .distantPast,
            modelSizes: SplatScene.ModelSizes(sog: 48_000_000)
        )

        XCTAssertNotEqual(plain, detailed)
        XCTAssertNil(plain.preset)
        XCTAssertEqual(plain.modelSizes, SplatScene.ModelSizes())
        XCTAssertEqual(detailed.modelSizes.sog, 48_000_000)
        XCTAssertNil(detailed.modelSizes.spz)
    }
}
