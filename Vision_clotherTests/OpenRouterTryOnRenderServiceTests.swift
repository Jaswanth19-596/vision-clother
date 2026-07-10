//
//  OpenRouterTryOnRenderServiceTests.swift
//  Vision_clotherTests
//

import Foundation
import Testing
@testable import Vision_clother

struct OpenRouterTryOnRenderServiceTests {

    @Test func parsesBase64ImageResponseSuccessfully() throws {
        let sampleResponse = """
        {
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": "Sure, here is your generated image.",
                "images": [
                  {
                    "type": "image_url",
                    "image_url": {
                      "url": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
                    }
                  }
                ]
              }
            }
          ]
        }
        """

        let service = OpenRouterTryOnRenderService()
        let responseData = try #require(sampleResponse.data(using: .utf8))
        let url = service.parseImageURL(from: responseData)

        #expect(url != nil)
        #expect(url?.isFileURL == true)
        
        if let fileURL = url {
            let fileData = try Data(contentsOf: fileURL)
            #expect(!fileData.isEmpty)
            // Cleanup test file
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    @Test func parsesLegacyContentDataURLResponse() throws {
        let sampleResponse = """
        {
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": "Here is the try-on result: data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
              }
            }
          ]
        }
        """

        let service = OpenRouterTryOnRenderService()
        let responseData = try #require(sampleResponse.data(using: .utf8))
        let url = service.parseImageURL(from: responseData)

        #expect(url != nil)
        #expect(url?.isFileURL == true)

        if let fileURL = url {
            let fileData = try Data(contentsOf: fileURL)
            #expect(!fileData.isEmpty)
            // Cleanup test file
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    @Test func parsesHTTPSURLResponseSuccessfully() throws {
        let sampleResponse = """
        {
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": "https://openrouter.ai/some-generated-image.png"
              }
            }
          ]
        }
        """

        let service = OpenRouterTryOnRenderService()
        let responseData = try #require(sampleResponse.data(using: .utf8))
        let url = service.parseImageURL(from: responseData)

        #expect(url != nil)
        #expect(url?.isFileURL == false)
        #expect(url?.absoluteString == "https://openrouter.ai/some-generated-image.png")
    }

    @Test func returnsNilForInvalidResponse() throws {
        let sampleResponse = """
        {
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": "Sorry, I encountered an error generating the image."
              }
            }
          ]
        }
        """

        let service = OpenRouterTryOnRenderService()
        let responseData = try #require(sampleResponse.data(using: .utf8))
        let url = service.parseImageURL(from: responseData)

        #expect(url == nil)
    }

    @Test func parsesImageAPIBase64ResponseSuccessfully() throws {
        let sampleResponse = """
        {
          "created": 1748372400,
          "data": [
            {
              "b64_json": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
            }
          ]
        }
        """

        let service = OpenRouterTryOnRenderService()
        let responseData = try #require(sampleResponse.data(using: .utf8))
        let url = service.parseImageAPIURL(from: responseData)

        #expect(url != nil)
        #expect(url?.isFileURL == true)

        if let fileURL = url {
            let fileData = try Data(contentsOf: fileURL)
            #expect(!fileData.isEmpty)
            // Cleanup test file
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    @Test func parsesImageAPIURLResponseSuccessfully() throws {
        let sampleResponse = """
        {
          "created": 1748372400,
          "data": [
            {
              "url": "https://openrouter.ai/image.png"
            }
          ]
        }
        """

        let service = OpenRouterTryOnRenderService()
        let responseData = try #require(sampleResponse.data(using: .utf8))
        let url = service.parseImageAPIURL(from: responseData)

        #expect(url != nil)
        #expect(url?.isFileURL == false)
        #expect(url?.absoluteString == "https://openrouter.ai/image.png")
    }
}
