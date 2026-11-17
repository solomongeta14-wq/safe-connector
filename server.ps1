$ErrorActionPreference = 'Stop'

$script:ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:DataDirectory = Join-Path $script:ProjectRoot 'data'
$script:DataFile = Join-Path $script:DataDirectory 'connect-safely.json'
$script:Port = 5173
$script:Listener = New-Object System.Net.HttpListener
$script:Sessions = @{}
$script:RateLimits = @{}
$script:AdminEmail = if ($env:CONNECT_ADMIN_EMAIL) { $env:CONNECT_ADMIN_EMAIL.Trim().ToLowerInvariant() } else { '' }

if (-not (Test-Path $script:DataDirectory)) {
  New-Item -ItemType Directory -Path $script:DataDirectory | Out-Null
}

if (Test-Path $script:DataFile) {
  $script:Database = Get-Content -Raw -Path $script:DataFile | ConvertFrom-Json
} else {
  $script:Database = [pscustomobject]@{
    users = @()
    likes = @()
    matches = @()
    notifications = @()
    conversations = @()
    contactRequests = @()
    reports = @()
    passwordResets = @()
    auditLog = @()
  }
}

if (-not $script:Database.PSObject.Properties.Name.Contains('passwordResets')) {
  $script:Database | Add-Member -MemberType NoteProperty -Name 'passwordResets' -Value @()
}

function Set-Property {
  param($Object, [string]$Name, $Value)
  $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
}

function Save-Database {
  $temporaryFile = "$($script:DataFile).tmp"
  $json = ConvertTo-Json -InputObject $script:Database -Depth 20
  [System.IO.File]::WriteAllText($temporaryFile, $json, (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -Path $temporaryFile -Destination $script:DataFile -Force
}

function Get-PasswordResetRecord {
  param([string]$Email)
  return @($script:Database.passwordResets | Where-Object { $_.email -eq $Email } | Sort-Object createdAt -Descending | Select-Object -First 1)
}

function New-Id {
  [guid]::NewGuid().ToString('N')
}

function New-Token {
  $bytes = New-Object byte[] 32
  $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $generator.GetBytes($bytes)
  } finally {
    $generator.Dispose()
  }
  [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-PasswordRecord {
  param([string]$Password)
  $salt = New-Object byte[] 16
  $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $generator.GetBytes($salt)
  } finally {
    $generator.Dispose()
  }
  $derive = [System.Security.Cryptography.Rfc2898DeriveBytes]::new(
    $Password,
    $salt,
    310000,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256
  )
  try {
    $hash = $derive.GetBytes(32)
  } finally {
    $derive.Dispose()
  }
  return "pbkdf2-sha256:310000:$([Convert]::ToBase64String($salt)):$([Convert]::ToBase64String($hash))"
}

function Test-Password {
  param([string]$Password, [string]$Record)
  $parts = $Record.Split(':')
  if ($parts.Length -ne 4 -or $parts[0] -ne 'pbkdf2-sha256' -or [int]$parts[1] -ne 310000) {
    return $false
  }
  try {
    $salt = [Convert]::FromBase64String($parts[2])
    $expected = [Convert]::FromBase64String($parts[3])
    $derive = [System.Security.Cryptography.Rfc2898DeriveBytes]::new(
      $Password,
      $salt,
      310000,
      [System.Security.Cryptography.HashAlgorithmName]::SHA256
    )
    try {
      $actual = $derive.GetBytes($expected.Length)
    } finally {
      $derive.Dispose()
    }
    if ($actual.Length -ne $expected.Length) { return $false }
    $difference = 0
    for ($index = 0; $index -lt $actual.Length; $index++) {
      $difference = $difference -bor ($actual[$index] -bxor $expected[$index])
    }
    return $difference -eq 0
  } catch {
    return $false
  }
}

function Get-Age {
  param([string]$DateOfBirth)
  $date = [datetime]::ParseExact($DateOfBirth, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
  $today = [datetime]::UtcNow.Date
  $age = $today.Year - $date.Year
  if ($date.Date -gt $today.AddYears(-$age)) { $age-- }
  return $age
}

function Get-UserById {
  param([string]$Id)
  return $script:Database.users | Where-Object { $_.id -eq $Id } | Select-Object -First 1
}

function Get-CurrentUser {
  param($Context)
  $cookie = $Context.Request.Cookies['cs_session']
  if (-not $cookie -or -not $script:Sessions.ContainsKey($cookie.Value)) { return $null }
  $session = $script:Sessions[$cookie.Value]
  if ($session.expires -lt [datetime]::UtcNow) {
    $script:Sessions.Remove($cookie.Value)
    return $null
  }
  return Get-UserById $session.userId
}

function Set-SessionCookie {
  param($Context, [string]$Token, [bool]$Expired = $false)
  $cookieValue = "cs_session=$Token; Path=/; HttpOnly; SameSite=Lax"
  if ($Context.Request.IsSecureConnection) { $cookieValue += '; Secure' }
  if ($Expired) {
    $cookieValue += '; Max-Age=0'
  } else {
    $cookieValue += '; Max-Age=43200'
  }
  $Context.Response.AppendHeader('Set-Cookie', $cookieValue)
}

function Add-Notification {
  param([string]$UserId, [string]$Type, [string]$Text, [string]$RequestId = '')
  $notification = [pscustomobject]@{
    id = New-Id
    userId = $UserId
    type = $Type
    text = $Text
    requestId = $RequestId
    read = $false
    createdAt = [datetime]::UtcNow.ToString('o')
  }
  $script:Database.notifications = @($script:Database.notifications) + @($notification)
}

function Add-AuditEntry {
  param([string]$Action, [string]$UserId)
  $entry = [pscustomobject]@{
    id = New-Id
    action = $Action
    userId = $UserId
    createdAt = [datetime]::UtcNow.ToString('o')
  }
  $script:Database.auditLog = @($script:Database.auditLog) + @($entry)
  if ($script:Database.auditLog.Count -gt 1000) {
    $script:Database.auditLog = @($script:Database.auditLog | Select-Object -Last 1000)
  }
}

function Get-PublicProfile {
  param($User)
  return [pscustomobject]@{
    id = $User.id
    displayName = $User.displayName
    gender = $User.gender
    age = Get-Age $User.dob
    country = $User.country
    city = $User.city
    aboutMe = $User.aboutMe
    occupation = $User.occupation
    education = $User.education
    interests = @($User.interests)
    languages = @($User.languages)
    relationshipIntent = $User.relationshipIntent
  }
}

function Get-PrivateProfile {
  param($User)
  $profile = Get-PublicProfile $User
  return [pscustomobject]@{
    id = $profile.id
    displayName = $profile.displayName
    gender = $profile.gender
    age = $profile.age
    country = $profile.country
    city = $profile.city
    aboutMe = $profile.aboutMe
    occupation = $profile.occupation
    education = $profile.education
    interests = $profile.interests
    languages = $profile.languages
    relationshipIntent = $profile.relationshipIntent
    ageRange = $User.ageRange
    preferredLocation = $User.preferredLocation
    isAdmin = [bool]$User.isAdmin
  }
}

function Send-Json {
  param($Context, [int]$StatusCode, $Value)
  $body = ConvertTo-Json -InputObject $Value -Depth 20 -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
  $Context.Response.StatusCode = $StatusCode
  $Context.Response.ContentType = 'application/json; charset=utf-8'
  $Context.Response.ContentLength64 = $bytes.Length
  $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $Context.Response.Close()
}

function Send-Message {
  param($Context, [int]$StatusCode, [string]$Message)
  Send-Json $Context $StatusCode ([pscustomobject]@{ error = $Message })
}

function Read-JsonBody {
  param($Context)
  if ($Context.Request.ContentLength64 -gt 65536) { throw 'Request body is too large.' }
  $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, $Context.Request.ContentEncoding)
  try {
    $body = $reader.ReadToEnd()
  } finally {
    $reader.Dispose()
  }
  if ([string]::IsNullOrWhiteSpace($body)) { throw 'A JSON request body is required.' }
  return ConvertFrom-Json -InputObject $body
}

function Test-RateLimit {
  param([string]$Key, [int]$Limit, [int]$WindowSeconds)
  $now = [datetime]::UtcNow
  if (-not $script:RateLimits.ContainsKey($Key) -or $script:RateLimits[$Key].expires -lt $now) {
    $script:RateLimits[$Key] = @{ count = 0; expires = $now.AddSeconds($WindowSeconds) }
  }
  $entry = $script:RateLimits[$Key]
  $entry.count++
  return $entry.count -le $Limit
}

function Test-MutatingOrigin {
  param($Context)
  $origin = $Context.Request.Headers['Origin']
  if ([string]::IsNullOrEmpty($origin)) { return $true }
  $expected = "http://localhost:$script:Port"
  return $origin -eq $expected -or $origin -eq "http://127.0.0.1:$script:Port"
}

function Get-NotificationPayload {
  param($UserId)
  $results = @($script:Database.notifications | Where-Object { $_.userId -eq $UserId } | Sort-Object createdAt -Descending | Select-Object -First 50 | ForEach-Object {
    $notification = $_
    $pendingRequest = $script:Database.contactRequests | Where-Object {
      $_.id -eq $notification.requestId -and $_.targetId -eq $UserId -and $_.status -eq 'pending'
    } | Select-Object -First 1
    [pscustomobject]@{
      id = $notification.id
      type = $notification.type
      text = $notification.text
      requestId = $notification.requestId
      read = [bool]$notification.read
      canRespond = [bool]($pendingRequest)
      createdAt = $notification.createdAt
    }
  })
  return ,$results
}

function Get-MatchesForUser {
  param($User)
  $results = @()
  foreach ($match in @($script:Database.matches | Where-Object { $_.user1 -eq $User.id -or $_.user2 -eq $User.id })) {
    $otherId = if ($match.user1 -eq $User.id) { $match.user2 } else { $match.user1 }
    $other = Get-UserById $otherId
    if ($other) {
      $results += [pscustomobject]@{
        id = $match.id
        userId = $other.id
        displayName = $other.displayName
        matchedAt = $match.createdAt
      }
    }
  }
  return ,$results
}

function Get-ConversationPayload {
  param($User)
  $results = @()
  foreach ($match in @($script:Database.matches | Where-Object { $_.user1 -eq $User.id -or $_.user2 -eq $User.id })) {
    $otherId = if ($match.user1 -eq $User.id) { $match.user2 } else { $match.user1 }
    $other = Get-UserById $otherId
    if (-not $other) { continue }
    $conversation = $script:Database.conversations | Where-Object { $_.matchId -eq $match.id } | Select-Object -First 1
    $messages = @()
    if ($conversation -and $conversation.messages) {
      $messages = @(@($conversation.messages) | ForEach-Object {
        [pscustomobject]@{ senderId = $_.senderId; text = $_.text; createdAt = $_.createdAt }
      })
    }
    $results += [pscustomobject]@{
      matchId = $match.id
      userId = $other.id
      displayName = $other.displayName
      messages = $messages
    }
  }
  return ,$results
}

function Handle-ApiRequest {
  param($Context)
  $request = $Context.Request
  $method = $request.HttpMethod
  $path = [uri]::UnescapeDataString($request.Url.AbsolutePath)
  $currentUser = Get-CurrentUser $Context
  $body = $null

  if ($method -in @('POST', 'PUT', 'PATCH', 'DELETE') -and -not (Test-MutatingOrigin $Context)) {
    Send-Message $Context 403 'Request origin is not allowed.'
    return
  }

  if ($method -eq 'GET' -and $path -eq '/api/health') {
    Send-Json $Context 200 ([pscustomobject]@{ status = 'ok'; service = 'connect-safely'; version = '1.0.0' })
    return
  }

  if ($method -eq 'POST' -and $path -eq '/api/register') {
    $ip = $request.RemoteEndPoint.Address.ToString()
    if (-not (Test-RateLimit "register:$ip" 5 3600)) {
      Send-Message $Context 429 'Too many registration attempts. Please try again later.'
      return
    }
    try { $body = Read-JsonBody $Context } catch {
      Send-Message $Context 400 $_.Exception.Message
      return
    }
    $email = ([string]$body.email).Trim().ToLowerInvariant()
    $name = ([string]$body.name).Trim()
    $displayName = ([string]$body.displayName).Trim()
    $password = [string]$body.password
    $dob = [string]$body.dob
    if (-not $body.termsAccepted) {
      Send-Message $Context 400 'You must accept the terms and confirm you are an adult.'
      return
    }
    if ($email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$' -or $name.Length -lt 2 -or $name.Length -gt 100 -or $displayName.Length -lt 2 -or $displayName.Length -gt 40) {
      Send-Message $Context 400 'Enter a valid email, name, and display name.'
      return
    }
    if ($password.Length -lt 10 -or $password.Length -gt 128) {
      Send-Message $Context 400 'Password must be between 10 and 128 characters.'
      return
    }
    try {
      if ((Get-Age $dob) -lt 18 -or (Get-Age $dob) -gt 120) {
        Send-Message $Context 400 'You must be at least 18 years old to register.'
        return
      }
    } catch {
      Send-Message $Context 400 'Enter a valid date of birth.'
      return
    }
    if ([string]$body.gender -notin @('man', 'woman', 'nonbinary')) {
      Send-Message $Context 400 'Select a valid gender.'
      return
    }
    if ($script:Database.users | Where-Object { $_.email -eq $email }) {
      Send-Message $Context 409 'An account with this email already exists.'
      return
    }
    $user = [pscustomobject]@{
      id = New-Id
      name = $name
      displayName = $displayName
      email = $email
      passwordHash = Get-PasswordRecord $password
      phone = ([string]$body.phone).Trim()
      gender = [string]$body.gender
      dob = $dob
      country = ([string]$body.country).Trim()
      city = ([string]$body.city).Trim()
      aboutMe = ''
      occupation = ''
      education = ''
      interests = @()
      languages = @()
      relationshipIntent = 'Long-term relationship'
      ageRange = ''
      preferredLocation = ''
      isAdmin = [bool]($script:AdminEmail -and $email -eq $script:AdminEmail)
      createdAt = [datetime]::UtcNow.ToString('o')
    }
    $script:Database.users = @($script:Database.users) + @($user)
    Add-AuditEntry 'account.register' $user.id
    Save-Database
    $token = New-Token
    $script:Sessions[$token] = @{ userId = $user.id; expires = [datetime]::UtcNow.AddHours(12) }
    Set-SessionCookie $Context $token
    Send-Json $Context 201 (Get-PrivateProfile $user)
    return
  }

  if ($method -eq 'POST' -and $path -eq '/api/login') {
    $ip = $request.RemoteEndPoint.Address.ToString()
    if (-not (Test-RateLimit "login:$ip" 10 900)) {
      Send-Message $Context 429 'Too many login attempts. Please wait and try again.'
      return
    }
    try { $body = Read-JsonBody $Context } catch {
      Send-Message $Context 400 $_.Exception.Message
      return
    }
    $email = ([string]$body.email).Trim().ToLowerInvariant()
    $user = $script:Database.users | Where-Object { $_.email -eq $email } | Select-Object -First 1
    if (-not $user -or -not (Test-Password ([string]$body.password) $user.passwordHash)) {
      Send-Message $Context 401 'Email or password is incorrect.'
      return
    }
    $token = New-Token
    $script:Sessions[$token] = @{ userId = $user.id; expires = [datetime]::UtcNow.AddHours(12) }
    Set-SessionCookie $Context $token
    Add-AuditEntry 'account.login' $user.id
    Save-Database
    Send-Json $Context 200 (Get-PrivateProfile $user)
    return
  }

  if ($method -eq 'POST' -and $path -eq '/api/logout') {
    if ($request.Cookies['cs_session']) {
      $script:Sessions.Remove($request.Cookies['cs_session'].Value)
    }
    Set-SessionCookie $Context '' $true
    Send-Json $Context 200 ([pscustomobject]@{ status = 'ok' })
    return
  }

  if ($method -eq 'POST' -and $path -eq '/api/password-reset/request') {
    try { $body = Read-JsonBody $Context } catch {
      Send-Message $Context 400 $_.Exception.Message
      return
    }
    $email = ([string]$body.email).Trim().ToLowerInvariant()
    if (-not ($email -match '^[^@\s]+@[^@\s]+\.[^@\s]+$')) {
      Send-Message $Context 400 'Enter a valid email address.'
      return
    }
    $user = $script:Database.users | Where-Object { $_.email -eq $email } | Select-Object -First 1
    if (-not $user) {
      Send-Message $Context 200 ([pscustomobject]@{ status = 'ok' })
      return
    }
    $bytes = New-Object byte[] 24
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
      $generator.GetBytes($bytes)
    } finally {
      $generator.Dispose()
    }
    $token = [System.Convert]::ToBase64String($bytes).Replace('+', '-').Replace('/', '_').TrimEnd('=')
    $expiresAt = [datetime]::UtcNow.AddHours(1)
    $existing = Get-PasswordResetRecord $email
    if ($existing) {
      Set-Property $existing[0] 'token' $token
      Set-Property $existing[0] 'expiresAt' $expiresAt.ToString('o')
      Set-Property $existing[0] 'createdAt' [datetime]::UtcNow.ToString('o')
    } else {
      $script:Database.passwordResets = @($script:Database.passwordResets) + @([pscustomobject]@{
        email = $email
        token = $token
        expiresAt = $expiresAt.ToString('o')
        createdAt = [datetime]::UtcNow.ToString('o')
      })
    }
    Add-AuditEntry 'account.password-reset-requested' $user.id
    Save-Database
    Send-Json $Context 200 ([pscustomobject]@{ status = 'ok'; token = $token })
    return
  }

  if ($method -eq 'POST' -and $path -eq '/api/password-reset/confirm') {
    try { $body = Read-JsonBody $Context } catch {
      Send-Message $Context 400 $_.Exception.Message
      return
    }
    $email = ([string]$body.email).Trim().ToLowerInvariant()
    $token = ([string]$body.token).Trim()
    $password = [string]$body.password
    if (-not ($email -match '^[^@\s]+@[^@\s]+\.[^@\s]+$') -or $token.Length -lt 8 -or $password.Length -lt 10 -or $password.Length -gt 128) {
      Send-Message $Context 400 'Use a valid email, reset token, and a password between 10 and 128 characters.'
      return
    }
    $reset = $script:Database.passwordResets | Where-Object { $_.email -eq $email -and $_.token -eq $token -and ([datetime]::Parse($_.expiresAt) -gt [datetime]::UtcNow) } | Select-Object -First 1
    if (-not $reset) {
      Send-Message $Context 400 'This password reset token is invalid or expired.'
      return
    }
    $user = $script:Database.users | Where-Object { $_.email -eq $email } | Select-Object -First 1
    if (-not $user) {
      Send-Message $Context 404 'No account matches this reset request.'
      return
    }
    Set-Property $user 'passwordHash' (Get-PasswordRecord $password)
    $script:Database.passwordResets = @($script:Database.passwordResets | Where-Object { $_.email -ne $email })
    Add-AuditEntry 'account.password-reset' $user.id
    Save-Database
    Send-Json $Context 200 ([pscustomobject]@{ status = 'ok' })
    return
  }

  if (-not $currentUser) {
    Send-Message $Context 401 'Please sign in to continue.'
    return
  }

  if ($method -eq 'GET' -and $path -eq '/api/me') {
    Send-Json $Context 200 (Get-PrivateProfile $currentUser)
    return
  }

  if ($method -eq 'PUT' -and $path -eq '/api/profile') {
    try { $body = Read-JsonBody $Context } catch {
      Send-Message $Context 400 $_.Exception.Message
      return
    }
    $displayName = ([string]$body.displayName).Trim()
    if ($displayName.Length -lt 2 -or $displayName.Length -gt 40) {
      Send-Message $Context 400 'Display name must be between 2 and 40 characters.'
      return
    }
    Set-Property $currentUser 'displayName' $displayName
    foreach ($field in @('country', 'city', 'occupation', 'education', 'aboutMe', 'relationshipIntent', 'ageRange', 'preferredLocation')) {
      $value = [string]$body.$field
      if ($value.Length -gt 500) {
        Send-Message $Context 400 "The $field field is too long."
        return
      }
      Set-Property $currentUser $field $value.Trim()
    }
    foreach ($field in @('interests', 'languages')) {
      $items = @($body.$field | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -First 20)
      Set-Property $currentUser $field $items
    }
    Add-AuditEntry 'profile.update' $currentUser.id
    Save-Database
    Send-Json $Context 200 (Get-PrivateProfile $currentUser)
    return
  }

  if ($method -eq 'GET' -and $path -eq '/api/profiles') {
    $search = ([string]$request.QueryString['search']).Trim().ToLowerInvariant()
    $gender = [string]$request.QueryString['gender']
    $country = ([string]$request.QueryString['country']).Trim()
    $seenIds = @($script:Database.likes | Where-Object { $_.fromId -eq $currentUser.id } | Select-Object -ExpandProperty toId)
    $blockedIds = @($script:Database.reports | Where-Object {
      $_.status -eq 'blocked' -and ($_.reporterId -eq $currentUser.id -or $_.targetId -eq $currentUser.id)
    } | ForEach-Object { if ($_.reporterId -eq $currentUser.id) { $_.targetId } else { $_.reporterId } })
    $profiles = @($script:Database.users | Where-Object {
      $_.id -ne $currentUser.id -and $_.id -notin $blockedIds -and $_.id -notin $seenIds -and
      (-not $search -or $_.displayName.ToLowerInvariant().Contains($search)) -and
      (-not $gender -or $gender -eq 'all' -or $_.gender -eq $gender) -and
      (-not $country -or $country -eq 'all' -or $_.country -eq $country)
    } | ForEach-Object { Get-PublicProfile $_ })
    Send-Json $Context 200 ([pscustomobject]@{
      profiles = $profiles
      countries = @($script:Database.users | Where-Object { $_.country } | Select-Object -ExpandProperty country -Unique)
    })
    return
  }

  if ($method -eq 'GET' -and $path -eq '/api/notifications') {
    Send-Json $Context 200 (Get-NotificationPayload $currentUser.id)
    return
  }

  if ($method -eq 'GET' -and $path -eq '/api/matches') {
    Send-Json $Context 200 (Get-MatchesForUser $currentUser)
    return
  }

  if ($method -eq 'POST' -and $path -eq '/api/interests') {
    try { $body = Read-JsonBody $Context } catch {
      Send-Message $Context 400 $_.Exception.Message
      return
    }
    $target = Get-UserById ([string]$body.targetId)
    if (-not $target -or $target.id -eq $currentUser.id -or [string]$body.action -notin @('like', 'pass')) {
      Send-Message $Context 400 'Invalid profile or interest action.'
      return
    }
    $existing = @($script:Database.likes | Where-Object { $_.fromId -eq $currentUser.id -and $_.toId -eq $target.id })
    if ($existing.Count) {
      Set-Property $existing[0] 'action' ([string]$body.action)
    } else {
      $script:Database.likes = @($script:Database.likes) + @([pscustomobject]@{
        fromId = $currentUser.id
        toId = $target.id
        action = [string]$body.action
        createdAt = [datetime]::UtcNow.ToString('o')
      })
    }
    $mutual = [string]$body.action -eq 'like' -and @($script:Database.likes | Where-Object {
      $_.fromId -eq $target.id -and $_.toId -eq $currentUser.id -and $_.action -eq 'like'
    }).Count -gt 0
    if ($mutual -and -not @($script:Database.matches | Where-Object { $_.user1 -eq $currentUser.id -and $_.user2 -eq $target.id -or $_.user1 -eq $target.id -and $_.user2 -eq $currentUser.id }).Count) {
      $match = [pscustomobject]@{
        id = New-Id
        user1 = $currentUser.id
        user2 = $target.id
        createdAt = [datetime]::UtcNow.ToString('o')
      }
      $script:Database.matches = @($script:Database.matches) + @($match)
      $script:Database.conversations = @($script:Database.conversations) + @([pscustomobject]@{ matchId = $match.id; messages = @() })
      Add-Notification $currentUser.id 'match' "You matched with $($target.displayName)." $match.id
      Add-Notification $target.id 'match' "You matched with $($currentUser.displayName)." $match.id
    } elseif ([string]$body.action -eq 'like') {
      Add-Notification $target.id 'interest' "$($currentUser.displayName) liked your profile." $currentUser.id
    }
    Add-AuditEntry "interest.$($body.action)" $currentUser.id
    Save-Database
    Send-Json $Context 200 ([pscustomobject]@{ matches = Get-MatchesForUser $currentUser })
    return
  }

  if ($method -eq 'GET' -and $path -eq '/api/conversations') {
    Send-Json $Context 200 (Get-ConversationPayload $currentUser)
    return
  }

  if ($method -eq 'POST' -and $path -eq '/api/messages') {
    try { $body = Read-JsonBody $Context } catch {
      Send-Message $Context 400 $_.Exception.Message
      return
    }
    $match = $script:Database.matches | Where-Object { $_.id -eq [string]$body.matchId -and ($_.user1 -eq $currentUser.id -or $_.user2 -eq $currentUser.id) } | Select-Object -First 1
    $text = ([string]$body.text).Trim()
    if (-not $match -or -not $text -or $text.Length -gt 2000) {
      Send-Message $Context 400 'Choose a match and enter a message of at most 2,000 characters.'
      return
    }
    $conversation = $script:Database.conversations | Where-Object { $_.matchId -eq $match.id } | Select-Object -First 1
    if (-not $conversation) {
      $conversation = [pscustomobject]@{ matchId = $match.id; messages = @() }
      $script:Database.conversations = @($script:Database.conversations) + @($conversation)
    }
    $message = [pscustomobject]@{ id = New-Id; senderId = $currentUser.id; text = $text; createdAt = [datetime]::UtcNow.ToString('o') }
    Set-Property $conversation 'messages' (@($conversation.messages) + @($message))
    $otherId = if ($match.user1 -eq $currentUser.id) { $match.user2 } else { $match.user1 }
    Add-Notification $otherId 'message' "You have a new message from $($currentUser.displayName)." $match.id
    Save-Database
    Send-Json $Context 201 ([pscustomobject]@{ id = $message.id; senderId = $message.senderId; text = $message.text; createdAt = $message.createdAt })
    return
  }

  if ($method -eq 'POST' -and $path -eq '/api/contact-requests') {
    try { $body = Read-JsonBody $Context } catch {
      Send-Message $Context 400 $_.Exception.Message
      return
    }
    $target = Get-UserById ([string]$body.targetId)
    $match = $script:Database.matches | Where-Object { ($_.user1 -eq $currentUser.id -and $_.user2 -eq [string]$body.targetId) -or ($_.user2 -eq $currentUser.id -and $_.user1 -eq [string]$body.targetId) } | Select-Object -First 1
    if (-not $target -or -not $match) {
      Send-Message $Context 403 'Contact exchange is available only to matched users.'
      return
    }
    $pending = $script:Database.contactRequests | Where-Object {
      (($_.requesterId -eq $currentUser.id -and $_.targetId -eq $target.id) -or ($_.requesterId -eq $target.id -and $_.targetId -eq $currentUser.id)) -and $_.status -eq 'pending'
    }
    if ($pending) {
      Send-Message $Context 409 'A contact exchange request is already pending.'
      return
    }
    $contactRequest = [pscustomobject]@{ id = New-Id; requesterId = $currentUser.id; targetId = $target.id; status = 'pending'; createdAt = [datetime]::UtcNow.ToString('o') }
    $script:Database.contactRequests = @($script:Database.contactRequests) + @($contactRequest)
    Add-Notification $target.id 'contact' "$($currentUser.displayName) requested a mutual contact exchange." $contactRequest.id
    Save-Database
    Send-Json $Context 201 ([pscustomobject]@{ id = $contactRequest.id; status = 'pending' })
    return
  }

  if ($method -eq 'POST' -and $path -eq '/api/contact-decisions') {
    try { $body = Read-JsonBody $Context } catch {
      Send-Message $Context 400 $_.Exception.Message
      return
    }
    $contactRequest = $script:Database.contactRequests | Where-Object { $_.id -eq [string]$body.requestId -and $_.targetId -eq $currentUser.id -and $_.status -eq 'pending' } | Select-Object -First 1
    if (-not $contactRequest -or [string]$body.decision -notin @('accept', 'decline')) {
      Send-Message $Context 404 'This contact request is no longer available.'
      return
    }
    Set-Property $contactRequest 'status' ([string]$body.decision + 'ed')
    if ([string]$body.decision -eq 'accept') {
      Add-Notification $contactRequest.requesterId 'contact' "$($currentUser.displayName) accepted your contact exchange request." $contactRequest.id
      Add-Notification $currentUser.id 'contact' 'Contact exchange accepted. Contact information is available in your matches.' $contactRequest.id
    }
    Save-Database
    Send-Json $Context 200 ([pscustomobject]@{ status = $contactRequest.status })
    return
  }

  if ($method -eq 'GET' -and $path -eq '/api/contacts') {
    $contacts = @()
    foreach ($requestRecord in @($script:Database.contactRequests | Where-Object { $_.status -eq 'accepted' -and ($_.requesterId -eq $currentUser.id -or $_.targetId -eq $currentUser.id) })) {
      $otherId = if ($requestRecord.requesterId -eq $currentUser.id) { $requestRecord.targetId } else { $requestRecord.requesterId }
      $other = Get-UserById $otherId
      if ($other) {
        $contacts += [pscustomobject]@{ userId = $other.id; displayName = $other.displayName; email = $other.email; phone = $other.phone }
      }
    }
    Send-Json $Context 200 $contacts
    return
  }

  if ($method -eq 'POST' -and $path -eq '/api/reports') {
    try { $body = Read-JsonBody $Context } catch {
      Send-Message $Context 400 $_.Exception.Message
      return
    }
    $target = Get-UserById ([string]$body.targetId)
    $reason = ([string]$body.reason).Trim()
    if (-not $target -or $target.id -eq $currentUser.id -or $reason.Length -lt 3 -or $reason.Length -gt 500) {
      Send-Message $Context 400 'Choose a valid profile and provide a short report reason.'
      return
    }
    $report = [pscustomobject]@{ id = New-Id; reporterId = $currentUser.id; targetId = $target.id; reason = $reason; status = 'pending'; createdAt = [datetime]::UtcNow.ToString('o') }
    $script:Database.reports = @($script:Database.reports) + @($report)
    Add-AuditEntry 'safety.report' $currentUser.id
    Save-Database
    Send-Json $Context 201 ([pscustomobject]@{ status = 'received' })
    return
  }

  if ($method -eq 'GET' -and $path -eq '/api/admin/reports') {
    if (-not $currentUser.isAdmin) {
      Send-Message $Context 403 'Administrator access is required.'
      return
    }
    $reports = @($script:Database.reports | ForEach-Object {
      $target = Get-UserById $_.targetId
      [pscustomobject]@{ id = $_.id; displayName = if ($target) { $target.displayName } else { 'Deleted account' }; reason = $_.reason; status = $_.status; createdAt = $_.createdAt }
    })
    Send-Json $Context 200 $reports
    return
  }

  if ($method -eq 'GET' -and $path -eq '/api/admin/stats') {
    if (-not $currentUser.isAdmin) {
      Send-Message $Context 403 'Administrator access is required.'
      return
    }
    Send-Json $Context 200 ([pscustomobject]@{
      users = @($script:Database.users).Count
      matches = @($script:Database.matches).Count
      openReports = @($script:Database.reports | Where-Object { $_.status -eq 'pending' -or $_.status -eq 'reviewing' }).Count
    })
    return
  }

  if ($method -eq 'PUT' -and $path -eq '/api/admin/reports') {
    if (-not $currentUser.isAdmin) {
      Send-Message $Context 403 'Administrator access is required.'
      return
    }
    try { $body = Read-JsonBody $Context } catch {
      Send-Message $Context 400 $_.Exception.Message
      return
    }
    $report = $script:Database.reports | Where-Object { $_.id -eq [string]$body.reportId } | Select-Object -First 1
    if (-not $report -or [string]$body.status -notin @('reviewing', 'resolved', 'dismissed')) {
      Send-Message $Context 400 'Select a report and a valid status.'
      return
    }
    Set-Property $report 'status' ([string]$body.status)
    Add-AuditEntry "report.$($body.status)" $currentUser.id
    Save-Database
    Send-Json $Context 200 ([pscustomobject]@{ status = $report.status })
    return
  }

  Send-Message $Context 404 'API endpoint not found.'
}

function Send-StaticFile {
  param($Context)
  $path = [uri]::UnescapeDataString($Context.Request.Url.AbsolutePath)
  if ($path -eq '/') { $path = '/index.html' }
  $fileName = [System.IO.Path]::GetFileName($path)
  if ($fileName -notin @('index.html', 'styles.css', 'app.js')) {
    $Context.Response.StatusCode = 404
    $Context.Response.Close()
    return
  }
  $filePath = Join-Path $script:ProjectRoot $fileName
  if (-not (Test-Path $filePath -PathType Leaf)) {
    $Context.Response.StatusCode = 404
    $Context.Response.Close()
    return
  }
  $contentType = switch ([System.IO.Path]::GetExtension($fileName)) {
    '.html' { 'text/html; charset=utf-8' }
    '.css' { 'text/css; charset=utf-8' }
    '.js' { 'application/javascript; charset=utf-8' }
  }
  $bytes = [System.IO.File]::ReadAllBytes($filePath)
  $Context.Response.StatusCode = 200
  $Context.Response.ContentType = $contentType
  $Context.Response.ContentLength64 = $bytes.Length
  $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $Context.Response.Close()
}

$script:Listener.Prefixes.Add("http://localhost:$script:Port/")
try {
  $script:Listener.Start()
} catch {
  Write-Error "Could not start the local server on http://localhost:$script:Port/. Close any process using that port and try again. Details: $($_.Exception.Message)"
  exit 1
}

Write-Host ''
Write-Host 'Connect Safely local server is running.' -ForegroundColor Green
Write-Host "Website: http://localhost:$script:Port/"
Write-Host "Health:  http://localhost:$script:Port/api/health"
Write-Host 'Press Ctrl+C to stop the server.'
Write-Host ''

try {
  while ($script:Listener.IsListening) {
    $context = $script:Listener.GetContext()
    $context.Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $context.Response.Headers['X-Frame-Options'] = 'DENY'
    $context.Response.Headers['Referrer-Policy'] = 'strict-origin-when-cross-origin'
    $context.Response.Headers['Content-Security-Policy'] = "default-src 'self'; style-src 'self' https://fonts.googleapis.com 'unsafe-inline'; font-src https://fonts.gstatic.com; script-src 'self'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'"
    $context.Response.Headers['Cache-Control'] = 'no-store'
    try {
      if ($context.Request.Url.AbsolutePath.StartsWith('/api/')) {
        Handle-ApiRequest $context
      } else {
        Send-StaticFile $context
      }
    } catch {
      Write-Warning "Request failed: $($_.Exception.Message)"
      try { Send-Message $context 500 'The server could not complete this request.' } catch {
        try { $context.Response.Close() } catch {}
      }
    }
  }
} finally {
  $script:Listener.Stop()
  $script:Listener.Close()
  Write-Host 'Server stopped.'
}
