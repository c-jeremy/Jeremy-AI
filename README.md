
# Jeremy-AI

A personal AI agent for Mac users while we still don't have system-level Siri AI. Built with SwiftUI with AppleScript under-hood, powered by Cloudflare Workers AI.

## Features
- **MenuBar Extra**: Access your agent instantly from the macOS status bar.
- **System Integration**: Seamlessly interacts with system apps like Calendar and Notes via AppleScript.

## Getting Started

### Prerequisites
- macOS 14.0+
- Xcode 14.0+
- A Cloudflare Account (with Workers AI enabled)

### Build & Run
1. Clone the repository via SSH:
```bash
git clone git@github.com:c-jeremy/Jeremy-AI.git
```

2. Navigate to the project directory and create your own configuration file from the template:

```bash
cp "Jeremy AI/Config.swift.example" "Jeremy AI/Config.swift"
```


3. Open `Config.swift.example` and fill in your Cloudflare credentials, learn more about [Cloudflare workers AI](
https://developers.cloudflare.com/workers-ai) and about [creating an API for Workers AI](https://developers.cloudflare.com/workers-ai/get-started/rest-api/):
```swift
static let cfAccountId = "YOUR_ACCOUNT_ID"
static let cfApiToken  = "YOUR_API_TOKEN"

```



4. Open `Jeremy AI.xcodeproj` in Xcode, choose your target, and press `⌘ R` to run!

## License

This project is licensed under the MIT License.

