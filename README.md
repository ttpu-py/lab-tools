# TTPU Lab tools

Tools for the Programming (Python) labs at Turin Polytechnic University in Tashkent.

## TTPU Lab launcher (`TTPU-Lab.cmd`)

Use it on **shared university PCs** when GitHub Codespaces is slow. It:

1. installs Git, VS Code, Python and the VS Code Python extensions if the PC does not have them (no admin rights needed),
2. removes old GitHub logins from the PC,
3. signs you in to GitHub once (a code in a private browser window),
4. downloads your lab repo and opens it in VS Code,
5. when you close VS Code: commits and pushes your work, and removes your login from the PC.

**Download:** [TTPU-Lab.cmd (latest)](https://github.com/ttpu-py/lab-tools/releases/latest/download/TTPU-Lab.cmd)

Open the downloaded file. If Windows shows "Windows protected your PC", click **More info -> Run anyway**. After the first run, use the **TTPU Lab** shortcut on the desktop.

The PC gets new versions of the launcher automatically from this repo's latest release.

Do **not** use it on your own laptop. There, clone your repo as usual.

Each lab README has the full steps.
