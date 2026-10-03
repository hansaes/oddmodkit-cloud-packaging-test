param(
    [string]$GitHubCli = 'gh',
    [string]$Repository = 'hansaes/oddmodkit-cloud-packaging-test'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
if ($env:GITHUB_ACTIONS -eq 'true') {
    throw 'Run this launcher with the existing local GitHub login, not inside Actions.'
}
if ($Repository -ne 'hansaes/oddmodkit-cloud-packaging-test') {
    throw 'This experiment is restricted to the dedicated test repository.'
}

Add-Type -AssemblyName System.Net.Http
$engineRevision = '585df42eb3a391efd295abd231333df20cddbcf3'
$token = (& $GitHubCli auth token | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $token) {
    throw 'The existing GitHub login is not available.'
}
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
if ($env:HTTPS_PROXY) {
    $handler.Proxy = [System.Net.WebProxy]::new($env:HTTPS_PROXY)
}
$client = [System.Net.Http.HttpClient]::new($handler)
$response = $null
$request = $null
try {
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('OddModKit-cloud-packaging-smoke')
    $client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, "https://api.github.com/repos/EpicGames/UnrealEngine/zipball/$engineRevision")
    $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    if ([int]$response.StatusCode -ne 302) {
        throw "Official engine archive authorization failed (HTTP $([int]$response.StatusCode))."
    }
    $archiveUri = $response.Headers.Location
    if ($archiveUri.Scheme -ne 'https' -or $archiveUri.Host -ne 'codeload.github.com' -or -not $archiveUri.AbsolutePath.EndsWith("/EpicGames/UnrealEngine/legacy.zip/$engineRevision", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unexpected official archive endpoint.'
    }
    $archiveUri.AbsoluteUri | & $GitHubCli secret set UE551_SOURCE_ARCHIVE_URL --repo $Repository
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to store the short-lived archive URL as an encrypted repository secret.'
    }
} finally {
    if ($response) { $response.Dispose() }
    if ($request) { $request.Dispose() }
    $client.Dispose()
    $token = $null
    $archiveUri = $null
}

& $GitHubCli workflow run package-smoke.yml --repo $Repository --ref main
if ($LASTEXITCODE -ne 0) {
    & $GitHubCli secret delete UE551_SOURCE_ARCHIVE_URL --repo $Repository
    throw 'Cloud workflow dispatch failed.'
}
Write-Host 'Cloud-only source build dispatched. The repository received a five-minute archive URL, not the local login token. No engine was downloaded locally.'
& $GitHubCli run list --repo $Repository --workflow package-smoke.yml --limit 1 --json databaseId,status,conclusion,url
