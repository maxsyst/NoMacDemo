# NoMacDemo - 云端构建 IPA 脚本（通过 GitHub API，无需直连 github.com）
# 用法: .\build-ipa-via-api.ps1 -Token "ghp_xxxx"
param(
    [Parameter(Mandatory=$true)]
    [string]$Token
)

$ErrorActionPreference = "Stop"
$base = "https://api.github.com"
$repoName = "NoMacDemo"
$headers = @{
    "Authorization" = "token $Token"
    "Accept"        = "application/vnd.github+json"
    "User-Agent"    = "NoMacDemo-Script"
}

function Invoke-GitHubApi {
    param($Method, $Path, $Body)
    $uri = "$base$Path"
    $params = @{ Method = $Method; Uri = $uri; Headers = $headers; ContentType = "application/json" }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress) }
    return Invoke-RestMethod @params
}

Write-Host "==> 1. 创建仓库 $repoName" -ForegroundColor Cyan
try {
    $repo = Invoke-GitHubApi -Method Post -Path "/user/repos" -Body @{
        name = $repoName
        private = $false
        auto_init = $false
    }
    $owner = $repo.owner.login
    Write-Host "    仓库已创建: $($repo.html_url)"
} catch {
    if ($_.Exception.Response.StatusCode -eq 422) {
        Write-Host "    仓库已存在，尝试获取..."
        $user = Invoke-GitHubApi -Method Get -Path "/user"
        $owner = $user.login
        $repo = Invoke-GitHubApi -Method Get -Path "/repos/$owner/$repoName"
        Write-Host "    使用已有仓库: $($repo.html_url)"
    } else { throw }
}

Write-Host "==> 2. 收集本地文件" -ForegroundColor Cyan
$projectRoot = "d:\MaxWorkSpaces\PromptsAgent\MyPaseo\NoMacDemo"
$files = @()
Get-ChildItem -Path $projectRoot -Recurse -File | Where-Object { $_.FullName -notmatch "\\\.git\\" } | ForEach-Object {
    $rel = $_.FullName.Substring($projectRoot.Length + 1).Replace("\", "/")
    $content = [System.IO.File]::ReadAllBytes($_.FullName)
    $b64 = [Convert]::ToBase64String($content)
    $files += @{ path = $rel; content = $b64 }
}
Write-Host "    找到 $($files.Count) 个文件"

Write-Host "==> 3. 通过 Git Data API 创建 Blobs + Tree + Commit" -ForegroundColor Cyan
$treeItems = @()
foreach ($f in $files) {
    $blob = Invoke-GitHubApi -Method Post -Path "/repos/$owner/$repoName/git/blobs" -Body @{
        content = $f.content
        encoding = "base64"
    }
    $treeItems += @{
        path = $f.path
        mode = "100644"
        type = "blob"
        sha = $blob.sha
    }
    Write-Host "    blob: $($f.path)"
}

$tree = Invoke-GitHubApi -Method Post -Path "/repos/$owner/$repoName/git/trees" -Body @{
    tree = $treeItems
}

# 获取默认分支最新 commit（如果有）
$parentSha = $null
try {
    $ref = Invoke-GitHubApi -Method Get -Path "/repos/$owner/$repoName/git/refs/heads/main"
    $parentSha = $ref.object.sha
} catch {
    try {
        $ref = Invoke-GitHubApi -Method Get -Path "/repos/$owner/$repoName/git/refs/heads/master"
        $parentSha = $ref.object.sha
        $branch = "master"
    } catch {
        Write-Host "    无现有分支，创建初始提交"
    }
}

$commitBody = @{
    message = "Initial commit: NoMacDemo iOS app"
    tree = $tree.sha
}
if ($parentSha) { $commitBody.parents = @($parentSha) }

$commit = Invoke-GitHubApi -Method Post -Path "/repos/$owner/$repoName/git/commits" -Body $commitBody
Write-Host "    提交已创建: $($commit.sha.Substring(0,7))"

# 更新/创建 main 分支引用
try {
    Invoke-GitHubApi -Method Patch -Path "/repos/$owner/$repoName/git/refs/heads/main" -Body @{
        sha = $commit.sha
        force = $true
    }
} catch {
    Invoke-GitHubApi -Method Post -Path "/repos/$owner/$repoName/git/refs" -Body @{
        ref = "refs/heads/main"
        sha = $commit.sha
    }
}
Write-Host "    main 分支已更新"

Write-Host "==> 4. 触发构建工作流" -ForegroundColor Cyan
Start-Sleep -Seconds 3
try {
    Invoke-GitHubApi -Method Post -Path "/repos/$owner/$repoName/actions/workflows/build-ipa.yml/dispatches" -Body @{
        ref = "main"
    }
    Write-Host "    工作流已触发"
} catch {
    Write-Host "    触发失败: $_"
    Write-Host "    尝试通过 push 事件自动触发..."
}

Write-Host "==> 5. 等待构建完成（最多 15 分钟）" -ForegroundColor Cyan
$timeout = 900
$elapsed = 0
$runId = $null
while ($elapsed -lt $timeout) {
    Start-Sleep -Seconds 15
    $elapsed += 15
    $runs = Invoke-GitHubApi -Method Get -Path "/repos/$owner/$repoName/actions/runs?per_page=1"
    if ($runs.workflow_runs.Count -gt 0) {
        $run = $runs.workflow_runs[0]
        $runId = $run.id
        Write-Host "    [$elapsed`s] Run #$($run.id) status=$($run.status) conclusion=$($run.conclusion)"
        if ($run.status -eq "completed") { break }
    } else {
        Write-Host "    [$elapsed`s] 等待工作流启动..."
    }
}

if (-not $runId) {
    Write-Error "未找到构建运行记录"
    exit 1
}

Write-Host "==> 6. 下载 IPA 产物" -ForegroundColor Cyan
$artifacts = Invoke-GitHubApi -Method Get -Path "/repos/$owner/$repoName/actions/runs/$runId/artifacts"
if ($artifacts.artifacts.Count -eq 0) {
    Write-Error "未找到产物，构建可能失败。请查看日志。"
    exit 1
}
$artifact = $artifacts.artifacts[0]
Write-Host "    产物: $($artifact.name) ($($artifact.size_in_bytes) bytes)"

$zipPath = "$projectRoot\build\$($artifact.name).zip"
New-Item -ItemType Directory -Force -Path "$projectRoot\build" | Out-Null
Invoke-WebRequest -Uri $artifact.archive_download_url -Headers $headers -OutFile $zipPath
Write-Host "    已下载: $zipPath"

Write-Host "==> 7. 解压 IPA" -ForegroundColor Cyan
Expand-Archive -Path $zipPath -DestinationPath "$projectRoot\build\ipa-output" -Force
$ipa = Get-ChildItem "$projectRoot\build\ipa-output" -Filter "*.ipa" -Recurse | Select-Object -First 1
if ($ipa) {
    $finalPath = "$projectRoot\$($ipa.Name)"
    Copy-Item $ipa.FullName $finalPath -Force
    Write-Host "`n==> 完成! IPA 文件: $finalPath" -ForegroundColor Green
} else {
    Write-Host "解压内容:" -ForegroundColor Yellow
    Get-ChildItem "$projectRoot\build\ipa-output" -Recurse | Select-Object FullName
}
