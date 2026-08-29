import CoreGraphics
import Foundation
import Testing
@testable import leanring_buddy

@MainActor
struct PetdexSpriteCatalogTests {
    @Test
    func searchResponseDecodesMissingOptionalMetadata() throws {
        let responseData = Data(
            """
            {
              "pets": [
                {
                  "slug": "boba",
                  "displayName": "Boba",
                  "spritesheetPath": "https://assets.petdex.dev/curated/boba/sprite-v2.webp",
                  "kind": "creature",
                  "submittedBy": { "name": "railly" },
                  "metrics": { "installCount": 9548 }
                }
              ],
              "nextCursor": 36,
              "total": 4669,
              "facets": {
                "kinds": { "creature": 1829 },
                "vibes": { "cozy": 915 }
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(
            PetdexSearchResponse.self,
            from: responseData
        )

        #expect(response.pets.count == 1)
        #expect(response.pets[0].slug == "boba")
        #expect(response.pets[0].vibes.isEmpty)
        #expect(response.pets[0].metrics.installCount == 9548)
        #expect(response.pets[0].metrics.likeCount == 0)
        #expect(response.nextCursor == 36)
        #expect(response.facets?.kinds["creature"] == 1829)
    }

    @Test
    func assetDownloadsRequireExactPetdexHTTPSHost() {
        #expect(
            PetdexSpriteCatalog.isTrustedAssetURL(
                URL(string: "https://assets.petdex.dev/pets/boba/sprite.webp")!
            )
        )
        #expect(
            !PetdexSpriteCatalog.isTrustedAssetURL(
                URL(string: "http://assets.petdex.dev/pets/boba/sprite.webp")!
            )
        )
        #expect(
            !PetdexSpriteCatalog.isTrustedAssetURL(
                URL(string: "https://assets.petdex.dev.evil.example/sprite.webp")!
            )
        )
        #expect(
            !PetdexSpriteCatalog.isTrustedAssetURL(
                URL(string: "https://assets.petdex.dev:8443/pets/boba/sprite.webp")!
            )
        )
    }

    @Test
    func assetDownloadsRejectOversizedDeclaredAndStreamedLengths() {
        let maximumByteCount = 1_024

        #expect(
            !PetdexAssetDownloadPolicy.expectedContentLengthExceedsLimit(
                Int64(maximumByteCount),
                maximumByteCount: maximumByteCount
            )
        )
        #expect(
            PetdexAssetDownloadPolicy.expectedContentLengthExceedsLimit(
                Int64(maximumByteCount + 1),
                maximumByteCount: maximumByteCount
            )
        )
        #expect(
            !PetdexAssetDownloadPolicy.expectedContentLengthExceedsLimit(
                NSURLSessionTransferSizeUnknown,
                maximumByteCount: maximumByteCount
            )
        )

        let byteCountAtLimit = PetdexAssetDownloadPolicy.receivedByteCount(
            afterAdding: 24,
            to: 1_000,
            maximumByteCount: maximumByteCount
        )
        let byteCountOverLimit = PetdexAssetDownloadPolicy.receivedByteCount(
            afterAdding: 25,
            to: 1_000,
            maximumByteCount: maximumByteCount
        )

        #expect(byteCountAtLimit == maximumByteCount)
        #expect(byteCountOverLimit == nil)
    }

    @Test
    func atlasLayoutAcceptsVersionOneAndVersionTwoGeometry() throws {
        let versionOneImage = try makeTransparentImage(width: 768, height: 936)
        let versionTwoImage = try makeTransparentImage(width: 1_536, height: 2_288)

        let versionOneLayout = try PetdexSpriteAtlasLayout.validatedLayout(
            for: versionOneImage
        )
        let versionTwoLayout = try PetdexSpriteAtlasLayout.validatedLayout(
            for: versionTwoImage
        )

        #expect(versionOneLayout.rowCount == 9)
        #expect(versionOneLayout.frameWidth == 96)
        #expect(versionOneLayout.frameHeight == 104)
        #expect(versionTwoLayout.rowCount == 11)
        #expect(versionTwoLayout.frameWidth == 192)
        #expect(versionTwoLayout.frameHeight == 208)

        let firstIdleFrame = try versionTwoLayout.frameRectangle(
            rowIndex: 0,
            columnIndex: 0
        )
        let firstRunningRightFrame = try versionTwoLayout.frameRectangle(
            rowIndex: 1,
            columnIndex: 0
        )
        #expect(firstIdleFrame.origin.y == 0)
        #expect(firstRunningRightFrame.origin.y == 208)
    }

    @Test
    func atlasLayoutRejectsUnsupportedGeometry() throws {
        let invalidImage = try makeTransparentImage(width: 1_536, height: 1_800)

        #expect(throws: PetdexCatalogError.self) {
            try PetdexSpriteAtlasLayout.validatedLayout(for: invalidImage)
        }
    }

    private func makeTransparentImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        return try #require(context.makeImage())
    }
}
