# thunderstore-modpack-downloader-cli
A bash script that downloads and assembles a thunderstore modpack.

Usage example:
```bash
./<name>.sh -y -z https://thunderstore.io/package/Author/Modpack/
./<name>.sh <r2modman-profile-code>
```
To see all flags use -h

Run the script from the directory where you want the build/ folder created. The script writes build/, staging/ and temporary files to its working directory.

Dependencies: bash, python3, curl, unzip, base64
Optional: zip, 7z, tar (for the -z flag)

The script was tested with: Lethal Company, REPO, Risk of Rain 2 and Valheim
