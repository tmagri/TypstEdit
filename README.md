# TypstEdit

<p align="center">
  <img src="TypstEdit/AppIcon.icns" alt="TypstEdit Icon" width="128" />
</p>

<p align="center">
  <b>A lightweight, native macOS editor for Typst.</b>
</p>

<p align="center">
  <a href="#installation">Download</a> • 
  <a href="#features">Features</a> • 
  <a href="#building-from-source">Build</a>
</p>

---

**TypstEdit** is a native SwiftUI application designed to make writing [Typst](https://typst.app) documents on macOS seamless and efficient. It combines a robust text editor with a live preview, leveraging the speed of the native Typst CLI.

![Screenshot of TypstEdit](screenshots/demo.png)
*(Note: Add a screenshot of your app here named demo.png inside a screenshots folder)*

## ✨ Features

* **⚡️ Live Preview:** Real-time compilation and preview of your document as you type.
* **🎨 Syntax Highlighting:** Native syntax highlighting for Typst code.
* **🍎 Native macOS Experience:** Built with SwiftUI for a fluid, responsive interface adhering to Apple's design guidelines.
* **🐞 Error Reporting:** Integrated error panel to quickly spot compilation issues.
* **🔢 Line Numbers:** Helpful ruler for code navigation.
* **📁 Project Sidebar:** Easily navigate through your project files.
* **🌑 Dark Mode Support:** Fully compatible with macOS system themes.

## 📥 Installation

The easiest way to install TypstEdit is to download the latest release.

1.  Go to the [Releases](../../releases) page.
2.  Download the `TypstEdit_Installer.dmg` file.
3.  Open the `.dmg` and drag the app to your **Applications** folder.

## 🛠️ Building from Source

If you want to contribute or build the app yourself:

### Prerequisites
* macOS 13.0+ (Ventura) or later.
* Xcode 15+ installed.
* Swift 5.9+.

### Steps

1.  **Clone the repository:**
    ```bash
    git clone [https://github.com/votre-nom-utilisateur/TypstEdit.git](https://github.com/votre-nom-utilisateur/TypstEdit.git)
    cd TypstEdit
    ```

2.  **Ensure the Typst binary is present:**
    The app requires the `typst` binary. Place the appropriate binary for your architecture in `TypstEdit/typst-aarch64-apple-darwin/typst` (or allow the script to handle it if configured).

3.  **Bundle and Build:**
    Use the included script to compile and create the bundle:
    ```bash
    chmod +x bundle.sh
    ./bundle.sh
    ```

4.  **Create Installer (Optional):**
    To generate the `.dmg` file:
    ```bash
    chmod +x create_dmg.sh
    ./create_dmg.sh
    ```

## 📄 License

This project is open source. [Add your license here, e.g., MIT License].

## ❤️ Credits

* Built for [Typst](https://typst.app).
* Uses the official Typst CLI binary.
