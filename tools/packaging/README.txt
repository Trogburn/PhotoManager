Photo Manager for Windows
==============================

This zip is a standalone Windows x64 build. You do not need the source
repository, Visual Studio, or the .NET SDK.

macOS is not supported. The application is built with Windows Presentation
Foundation and will not run on a Mac.

Install
-------
1. Extract this zip to a folder.
2. Double-click Install.bat.
3. The app installs to %LOCALAPPDATA%\PhotoManager and adds a Start Menu
   shortcut named "Photo Manager".
4. No administrator rights are required.

You can also run PhotoManager.exe from the extracted folder without
installing.

For the full first-use walkthrough, open GETTING_STARTED.md in this zip.

First use
---------
1. Enter a UNC folder (\\server\share\Photos) or a local folder (D:\Photos).
   Do not use a drive root or a mapped network letter.
2. Enter a quarantine folder that is outside that photo tree.
3. Keep the artifact folder on this PC (the default "artifacts" folder next
   to the app is fine).
4. Create a NAS snapshot or other backup before Apply.
5. Review, then apply a small batch first.

Requirements
------------
- Windows 10 or 11, 64-bit
- PowerShell (included with Windows)
- Access to your photo folder (UNC share or local folder)

The .NET runtime is included in this package. Czkawka CLI 12.0.1 is included
and checksum-verified at pack time.
