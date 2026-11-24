param([switch]$Force)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = $PSScriptRoot
Set-Location -LiteralPath $root
$repository = $env:GITHUB_REPOSITORY
if ($repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw 'GITHUB_REPOSITORY must identify the Neko repository.'
}

function Invoke-Native {
    param([string]$Program, [Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}

$headers = @{ 'User-Agent' = 'Neko-release-builder' }
$upstream = Invoke-RestMethod 'https://api.github.com/repos/madoiscool/BetterSteamTools/releases/latest' -Headers $headers
$upstreamVersion = $upstream.tag_name
if ($upstreamVersion -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw 'Invalid upstream release tag.' }
$patchHash = (Get-FileHash -LiteralPath (Join-Path $root 'neko.patch') -Algorithm SHA256).Hash
$builderHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
$revisionBytes = [Text.Encoding]::UTF8.GetBytes($patchHash + $builderHash)
$revision = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($revisionBytes)).ToLower().Substring(0, 12)
$version = "$upstreamVersion-neko.$revision"

if (!$Force) {
    try {
        $published = Invoke-WebRequest "https://raw.githubusercontent.com/$repository/updates/neko/latest.toml" -Headers $headers
        if ($published.Content.Contains('version = "' + $version + '"')) {
            Write-Output "Neko is current: $version"
            exit 0
        }
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -ne 404) { throw }
    }
}

$work = Join-Path $root '_neko-work'
if (Test-Path -LiteralPath $work) { throw 'Build workspace already exists. Use a fresh checkout.' }
New-Item -ItemType Directory -Path $work | Out-Null
$source = Join-Path $work 'source'
Invoke-Native git @('clone', '--depth', '1', '--branch', $upstreamVersion,
    'https://github.com/madoiscool/BetterSteamTools.git', $source)
$upstreamCommit = (& git -C $source rev-parse HEAD).Trim()
# Supply the patch's original blobs so three-way application can preserve future upstream edits.
Invoke-Native git @('-C', $source, 'fetch', '--depth', '1', 'origin', '6c4ed99a15e8e5719f32bc1ee828d0a6817d541a')
Invoke-Native git @('-C', $source, 'apply', '--check', '--3way', (Join-Path $root 'neko.patch'))
Invoke-Native git @('-C', $source, 'apply', '--3way', (Join-Path $root 'neko.patch'))
$build = Join-Path $work 'build'
Invoke-Native cmake @('-S', (Join-Path $source 'src'), '-B', $build, '-G', 'Ninja Multi-Config',
    "-DOPENSTEAMTOOL_VERSION=$version", "-DNEKO_UPDATE_REPOSITORY=$repository",
    "-DOST_DEPS_DIR=$(Join-Path $root '.deps')")
Invoke-Native cmake @('--build', $build, '--config', 'Release', '--parallel', '4',
    '--target', 'OpenSteamTool', 'dwmapi', 'xinput1_4')

$tests = Join-Path $work 'tests'
New-Item -ItemType Directory -Path $tests | Out-Null
$verifier = Join-Path $tests 'verify-neko-update.exe'
Invoke-Native cl @('/nologo', '/std:c++20', '/EHsc', '/O2', '/Gy', '/MT',
    "/I$source/src", "/I$source/src/OSTPlatform", "/I$build/generated", "/I$root/.deps/tomlplusplus-src/include",
    (Join-Path $root 'verify-neko-update.cpp'), "$source/src/Utils/Update/AppUpdater.cpp",
    "$source/src/OSTPlatform/Windows/Hash.cpp", "/Fo:$tests/", "/Fe:$verifier",
    '/link', '/OPT:REF', 'bcrypt.lib')
Invoke-Native $verifier @("$build/Release/Neko.dll", (Join-Path $tests 'staging'))
foreach ($loader in @('dwmapi.dll', 'xinput1_4.dll')) {
    $loaderBytes = [IO.File]::ReadAllBytes("$build/Release/$loader")
    $loaderText = [Text.Encoding]::ASCII.GetString($loaderBytes)
    if (!$loaderText.Contains('Neko.dll') -or $loaderText.Contains('OpenSteamTool.dll')) {
        throw "Loader still references an upstream DLL: $loader"
    }
}

$package = Join-Path $work 'Neko'
New-Item -ItemType Directory -Path $package | Out-Null
foreach ($name in @('Neko.dll', 'dwmapi.dll', 'xinput1_4.dll')) {
    Copy-Item -LiteralPath "$build/Release/$name" -Destination (Join-Path $package $name)
}
foreach ($name in @('Neko.example.toml', 'LICENSE', 'README.md', 'README_ES.md', 'README_ZH.md')) {
    Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $package $name)
}
Copy-Item -LiteralPath (Join-Path $package 'Neko.example.toml') -Destination (Join-Path $package 'Neko.toml')
$archive = Join-Path $work "Neko-$version.zip"
Compress-Archive -Path "$package/*" -DestinationPath $archive
$sourceArchive = Join-Path $work "Neko-$version-source.zip"
$sourceFiles = @(Get-ChildItem -LiteralPath $source -Force | Where-Object Name -ne '.git')
Compress-Archive -LiteralPath $sourceFiles.FullName -DestinationPath $sourceArchive

# Keep the fork's buildable source aligned with the successfully tested release.
Copy-Item -Path "$source/src/*" -Destination (Join-Path $root 'src') -Recurse -Force
foreach ($name in @('Neko.example.toml', 'README.md', 'README_ES.md', 'README_ZH.md')) {
    Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $root $name) -Force
}
Invoke-Native git @('config', 'user.name', 'Neko release builder')
Invoke-Native git @('config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com')
Invoke-Native git @('add', '--', 'src', 'README.md', 'README_ES.md', 'README_ZH.md', 'Neko.example.toml')
Invoke-Native git @('rm', '--ignore-unmatch', '--', 'opensteamtool.example.toml')
& git diff --cached --quiet
if ($LASTEXITCODE -eq 1) {
    Invoke-Native git @('commit', '-m', "Build Neko from upstream $upstreamVersion ($upstreamCommit)")
    Invoke-Native git @('push', 'origin', 'HEAD:main')
} elseif ($LASTEXITCODE -ne 0) { throw 'Could not inspect source changes.' }

$notes = Join-Path $work 'release-notes.md'
@"
Neko $version

Built from madoiscool/BetterSteamTools $upstreamVersion, commit $upstreamCommit.
Neko branding and update checks were applied and verified before publication.
The source archive includes the corresponding modified source and upstream GPL license.
"@ | Set-Content -LiteralPath $notes -Encoding utf8
& gh release view $version --repo $repository *> $null
if ($LASTEXITCODE -eq 0) {
    Invoke-Native gh @('release', 'upload', $version, $archive, $sourceArchive, '--clobber', '--repo', $repository)
} else {
    $target = (& git rev-parse HEAD).Trim()
    Invoke-Native gh @('release', 'create', $version, $archive, $sourceArchive, '--repo', $repository,
        '--target', $target, '--title', "Neko $version", '--notes-file', $notes)
}

# Publish the version pointer only after a branded build, tests and release succeed.
$publish = Join-Path $work 'publish'
& git ls-remote --exit-code origin refs/heads/updates *> $null
if ($LASTEXITCODE -eq 0) {
    Invoke-Native git @('fetch', 'origin', 'updates')
    Invoke-Native git @('worktree', 'add', '--detach', $publish, 'FETCH_HEAD')
} else {
    Invoke-Native git @('worktree', 'add', '--detach', $publish, 'HEAD')
    Invoke-Native git @('-C', $publish, 'switch', '--orphan', 'updates')
}
$releaseDirectory = Join-Path $publish "neko/$version"
New-Item -ItemType Directory -Path $releaseDirectory -Force | Out-Null
Copy-Item -LiteralPath "$build/Release/Neko.dll" -Destination (Join-Path $releaseDirectory 'Neko.dll')
$hash = (Get-FileHash -LiteralPath "$build/Release/Neko.dll" -Algorithm SHA256).Hash.ToLower()
@"
product = "Neko"
format = 1
version = "$version"
path = "neko/$version/Neko.dll"
sha256 = "$hash"
upstream_version = "$upstreamVersion"
upstream_commit = "$upstreamCommit"
"@ | Set-Content -LiteralPath (Join-Path $publish 'neko/latest.toml') -Encoding utf8
Invoke-Native git @('-C', $publish, 'add', '--', 'neko')
Invoke-Native git @('-C', $publish, 'commit', '-m', "Publish Neko $version")
Invoke-Native git @('-C', $publish, 'push', 'origin', 'HEAD:updates')
Write-Output "Published Neko $version"
