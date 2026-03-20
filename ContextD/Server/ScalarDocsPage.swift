import Foundation

/// Generates the Scalar API docs HTML page.
/// Scalar is loaded from CDN, single HTML page, no build step needed.
enum ScalarDocsPage {
    static func html(port: Int) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <title>ContextD API Docs</title>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            <style>
                body { margin: 0; padding: 0; }
            </style>
        </head>
        <body>
            <script
                id="api-reference"
                data-url="http://127.0.0.1:\(port)/openapi.json"
                data-configuration='{"theme":"default"}'
            ></script>
            <script src="https://cdn.jsdelivr.net/npm/@scalar/api-reference"></script>
        </body>
        </html>
        """
    }
}
