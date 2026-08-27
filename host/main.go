package main

import (
    "os"
    "os/exec"
    "path/filepath"
    "syscall"
)

func main() {
    exe, err := os.Executable()
    if err != nil { return }
    root := filepath.Dir(exe)
    script := filepath.Join(root, "launcher.ps1")
    ps := filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
    if os.Getenv("SystemRoot") == "" { ps = "powershell.exe" }

    cmd := exec.Command(ps,
        "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-WindowStyle", "Hidden", "-File", script,
    )
    cmd.Dir = root
    cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
    _ = cmd.Run()
}