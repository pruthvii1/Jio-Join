# Calling-only Windows controller. Secrets remain in memory and anonymous process pipes.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$created = $false
$mutex = [Threading.Mutex]::new($true, 'Local\JioJoinDesktop-Protocol1', [ref]$created)
if (-not $created) { [Windows.MessageBox]::Show('JioJoin Desktop is already running.'); exit 2 }
$script:engine = $null; $script:cookie = $null; $script:credentials = $null
$script:lastPong = [DateTime]::UtcNow; $script:inCall = $false
$identityDir = Join-Path $env:LOCALAPPDATA 'JioJoin Desktop'
$identityPath = Join-Path $identityDir 'device-id.txt'
if (Test-Path $identityPath) { $script:device = (Get-Content -LiteralPath $identityPath -Raw).Trim() }
else {
  New-Item -ItemType Directory -Path $identityDir -Force | Out-Null
  $script:device = 'JioJoinWindows-' + ([guid]::NewGuid().ToString('N').Substring(0,8))
  [IO.File]::WriteAllText($identityPath, $script:device, [Text.UTF8Encoding]::new($false))
}
if ($script:device -notmatch '^JioJoinWindows-[0-9a-f]{8}$') { throw 'The local non-secret device identity is invalid.' }
$script:routerIP = $null; $script:held = $false

function Private-IP([string]$value) {
  $ip = $null
  if (-not [Net.IPAddress]::TryParse($value, [ref]$ip) -or $ip.AddressFamily -ne 'InterNetwork') { return $false }
  $b = $ip.GetAddressBytes(); return $b[0] -eq 10 -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168)
}
function Device-Mac([string]$alias) {
  [uint32]$hash = 0; foreach ($byte in [Text.Encoding]::UTF8.GetBytes($alias)) { $hash = [uint32](($hash * 33 + $byte) -band 0xffffffffL) }
  $bytes = 0,0,($hash -band 255),(($hash -shr 8)-band 255),(($hash -shr 16)-band 255),(($hash -shr 24)-band 255)
  return ($bytes | ForEach-Object { $_.ToString('x2') }) -join ':'
}
function Gateway {
  $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Where-Object { Private-IP $_.NextHop } | Sort-Object RouteMetric | Select-Object -First 1
  if (-not $route) { throw 'No private IPv4 default gateway is available.' }; return $route.NextHop
}
function Router-Request([hashtable]$items) {
  if (-not $script:routerIP) { $script:routerIP = Gateway }
  if (-not (Private-IP $script:routerIP)) { throw 'The Jio router must use a private IPv4 address.' }
  $pairs = foreach ($key in $items.Keys) { [Uri]::EscapeDataString($key)+'='+[Uri]::EscapeDataString([string]$items[$key]) }
  $url = 'https://jiofiber.local.html:8443/?' + ($pairs -join '&')
  $handler = [Net.Http.HttpClientHandler]::new()
  $handler.ServerCertificateCustomValidationCallback = { param($m,$c,$ch,$e) $m.RequestUri.Host -eq 'jiofiber.local.html' -and (Private-IP $script:routerIP) }
  $client = [Net.Http.HttpClient]::new($handler); $client.Timeout = [TimeSpan]::FromSeconds(15)
  if ($script:cookie) { $client.DefaultRequestHeaders.Add('Cookie', $script:cookie) }
  $builder = [UriBuilder]$url; $builder.Host = $script:routerIP
  $request = [Net.Http.HttpRequestMessage]::new('GET', $builder.Uri); $request.Headers.Host = 'jiofiber.local.html:8443'
  $response = $client.SendAsync($request).GetAwaiter().GetResult()
  if ($response.Headers.TryGetValues('Set-Cookie',[ref]$cookies)) { $script:cookie = ($cookies | Select-Object -First 1).Split(';')[0] }
  if (-not $response.IsSuccessStatusCode) { throw "Router request failed with HTTP $([int]$response.StatusCode)." }
  return $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
}
function Account-Items {
  $mac = Device-Mac $script:device
  return @{terminal_sw_version='7.1.2';SMS_port='0';act_type='volatile';IMSI='';msisdn='';IMEI='';vers='0';token='';rcs_state='0';rcs_version='5.1B';rcs_profile='joyn_blackbird';client_vendor='WITS';default_sms_app='1';default_vvm_app='0';device_type='vvm';client_version='RCSAndrd-5.3';provisioning_version='2.0';nwk_intf='wifi';terminal_vendor=$script:device;terminal_model=$script:device;mac_address=$mac;alias=$script:device;op_type='add'}
}
function Parse-Credentials([string]$text) {
  if ([string]::IsNullOrWhiteSpace($text)) { throw 'This Windows device needs router OTP authorization.' }
  [xml]$xml = $text; $values=@{}
  foreach ($node in $xml.SelectNodes('//*[local-name()="parm"]')) { $values[$node.name.ToLowerInvariant()] = $node.value }
  foreach ($required in 'realm','userpwd','public_user_identity','private_user_identity') { if (-not $values[$required]) { throw "Provisioning omitted $required." } }
  $proxy = $values['lbo_p-cscf_address']; if (-not $proxy) { $proxy='jiofiber.local.html:5068' }
  $public=$values['public_user_identity']; if (-not $public.StartsWith('sip:')) { $public='sip:'+$public }
  $auth=$values['private_user_identity'] -replace '^sip:',''; $registrar='sip:'+$proxy+';transport=tls'
  $mac=(Device-Mac $script:device).Replace(':','').ToUpperInvariant(); $instance='<00000000-0000-1000-8000-'+$mac+'>'
  $digits=$public -replace '\D',''; $psap=$values['psoltid']; if (-not $psap) {$psap=$digits}; if (-not $psap.StartsWith('+')) {$psap='+'+$psap}
  return @($public,$auth,$values['userpwd'],$values['realm'],$registrar,$instance,(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { Private-IP $_.IPAddress } | Select-Object -First 1 -ExpandProperty IPAddress),'GPON;PSAPId='+$psap)
}
function B64([string]$v) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($v)) }
function Send-Engine([string]$line) { if (-not $script:engine -or $script:engine.HasExited) { throw 'Calling engine is unavailable.' }; $script:engine.StandardInput.WriteLine($line); $script:engine.StandardInput.Flush() }
function Start-Engine($credentials) {
  if ($script:inCall) { throw 'End the active call before reconnecting.' }
  Stop-Engine
  $path=Join-Path $PSScriptRoot 'jiojoin-engine.exe'; if (-not (Test-Path $path)) { throw 'jiojoin-engine.exe is missing.' }
  $psi=[Diagnostics.ProcessStartInfo]::new($path,'--stdio'); $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true; $psi.RedirectStandardInput=$true; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$false
  if ($Capture.SelectedItem -and $Playback.SelectedItem) { $psi.EnvironmentVariables['JIOJOIN_CAPTURE_DEVICE']=[string]$Capture.SelectedItem; $psi.EnvironmentVariables['JIOJOIN_PLAYBACK_DEVICE']=[string]$Playback.SelectedItem }
  elseif ($Capture.SelectedItem -or $Playback.SelectedItem) { throw 'Choose both microphone and speaker, or use both system defaults.' }
  $script:engine=[Diagnostics.Process]::new(); $script:engine.StartInfo=$psi; [void]$script:engine.Start()
  $hello=$script:engine.StandardOutput.ReadLine() | ConvertFrom-Json
  if ($hello.event -ne 'hello' -or $hello.protocol -ne 1 -or $hello.platform -ne 'windows' -or $hello.architecture -ne 'x86_64') { Stop-Engine; throw 'Engine protocol/platform handshake failed.' }
  $script:lastPong = [DateTime]::UtcNow
  $script:engine.add_OutputDataReceived({ param($s,$e) if ($e.Data) { $window.Dispatcher.Invoke([action]{ Handle-Event ($e.Data | ConvertFrom-Json) }) } }); $script:engine.BeginOutputReadLine()
  Send-Engine ('START`t'+(($credentials | ForEach-Object { B64 $_ }) -join "`t")); Set-State 'Connecting' 'Waiting for JioFiber registration'
}
function Stop-Engine { if ($script:engine -and -not $script:engine.HasExited) { try { Send-Engine 'QUIT'; $script:engine.WaitForExit(3000) | Out-Null } catch {}; if (-not $script:engine.HasExited) {$script:engine.Kill()} }; $script:engine=$null; $script:credentials=$null; $script:inCall=$false }
function Set-State($state,$detail) { $Status.Text=$state; $Detail.Text=$detail }
function Log($line) { $Diagnostics.AppendText($line+"`r`n"); $Diagnostics.ScrollToEnd() }
function Handle-Event($event) {
  switch ($event.event) {
    'pong' { $script:lastPong = [DateTime]::UtcNow }
    'registered' { Set-State 'Ready for calls' 'Registered on JioFiber (SIP 200)' }
    'registration' { if ($event.code -ge 300) {Set-State 'Connection failed' "SIP $($event.code): $($event.message)"} else {Set-State 'Connecting' $event.message} }
    'incoming' { $script:inCall=$true; Set-State 'Incoming call' 'Answer or reject' }
    'dialing' { $script:inCall=$true; Set-State 'Calling' $event.message }
    'call-state' { $script:inCall=($event.message -ne 'DISCONNECTED'); Set-State $(if($script:inCall){'Call active'}else{'Ready for calls'}) $event.message }
    'held' { $script:held=$true; Set-State 'Call on hold' $event.message }
    'resumed' { $script:held=$false; Set-State 'Call active' $event.message }
    'media' { $script:inCall=$true; Set-State 'Call active' $event.message }
    'error' { Set-State 'Engine error' "$($event.message) ($($event.code))" }
  }
  if ($event.event -notin 'pong','status','hello') { Log "$($event.event): $($event.message) [$($event.code)]" }
}

[xml]$xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="JioJoin Desktop" Width="520" Height="700" MinWidth="460" MinHeight="620">
 <ScrollViewer><StackPanel Margin="22"><TextBlock Text="JioJoin" FontSize="30" FontWeight="SemiBold"/><Border Padding="14" Margin="0,14" Background="#F0F4F8" CornerRadius="8"><StackPanel><TextBlock Name="Status" Text="Offline" FontSize="19" FontWeight="SemiBold"/><TextBlock Name="Detail" Text="Disconnected by user" TextWrapping="Wrap"/></StackPanel></Border>
 <GroupBox Header="Connection"><StackPanel Margin="8"><WrapPanel><Button Name="Connect" Content="Connect" Padding="14,6"/><Button Name="Request" Content="Request OTP" Margin="6,0" Padding="14,6"/><PasswordBox Name="OTP" Width="90"/><Button Name="Verify" Content="Verify" Margin="6,0" Padding="14,6"/><Button Name="Disconnect" Content="Disconnect" Padding="14,6"/></WrapPanel></StackPanel></GroupBox>
 <GroupBox Header="Call" Margin="0,14"><StackPanel Margin="8"><TextBox Name="Number" FontSize="22" HorizontalContentAlignment="Center"/><UniformGrid Columns="3" Name="Keypad" Margin="70,8"/><WrapPanel HorizontalAlignment="Center"><Button Name="Call" Content="Call" Padding="13,6"/><Button Name="Answer" Content="Answer" Margin="5,0" Padding="13,6"/><Button Name="Reject" Content="Reject" Padding="13,6"/><Button Name="Hangup" Content="Hang up" Margin="5,0" Padding="13,6"/><Button Name="Hold" Content="Hold / Resume" Padding="13,6"/></WrapPanel></StackPanel></GroupBox>
 <GroupBox Header="Audio devices (applies on reconnect)" Margin="0,0,0,14"><Grid Margin="8"><Grid.ColumnDefinitions><ColumnDefinition Width="100"/><ColumnDefinition/></Grid.ColumnDefinitions><Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions><TextBlock Text="Microphone"/><ComboBox Name="Capture" Grid.Column="1"/><TextBlock Text="Speaker" Grid.Row="1"/><ComboBox Name="Playback" Grid.Row="1" Grid.Column="1"/></Grid></GroupBox>
 <GroupBox Header="Redacted diagnostics"><TextBox Name="Diagnostics" Height="150" Margin="8" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/></GroupBox></StackPanel></ScrollViewer>
</Window>
'@
$reader=[Xml.XmlNodeReader]::new($xaml); $window=[Windows.Markup.XamlReader]::Load($reader)
foreach($name in 'Status','Detail','OTP','Number','Keypad','Diagnostics','Capture','Playback','Connect','Request','Verify','Disconnect','Call','Answer','Reject','Hangup','Hold'){Set-Variable -Name $name -Value $window.FindName($name) -Scope Script}
$heartbeat = [Windows.Threading.DispatcherTimer]::new()
$heartbeat.Interval = [TimeSpan]::FromSeconds(10)
$heartbeat.Add_Tick({
  if ($script:engine -and -not $script:engine.HasExited) {
    if (([DateTime]::UtcNow - $script:lastPong).TotalSeconds -gt 35) {
      Stop-Engine; Set-State 'Engine failure' 'The calling engine stopped responding. Use Connect to retry.'
    } else { try { Send-Engine 'PING' } catch { Stop-Engine; Set-State 'Engine failure' 'The calling engine exited. Use Connect to retry.' } }
  }
})
$heartbeat.Start()
try {
  $options = & (Join-Path $PSScriptRoot 'jiojoin-engine.exe') --list-audio 2>$null | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object event -eq 'audio-device-option'
  foreach($option in $options) { if($option.capture){[void]$Capture.Items.Add($option.message)};if($option.playback){[void]$Playback.Items.Add($option.message)} }
} catch { Log "audio: native device enumeration unavailable" }
foreach($digit in '1','2','3','4','5','6','7','8','9','*','0','#'){ $b=[Windows.Controls.Button]::new();$b.Content=$digit;$b.Margin=2;$b.Padding='8';$b.Add_Click({$Number.Text += $this.Content});$Keypad.Children.Add($b)|Out-Null }
$Connect.Add_Click({try{$script:credentials=Parse-Credentials (Router-Request (Account-Items));Start-Engine $script:credentials}catch{Set-State 'Connection failed' $_.Exception.Message;Log "controller: $($_.Exception.Message)"}})
$Request.Add_Click({try{$body=Router-Request (Account-Items);if($body){$script:credentials=Parse-Credentials $body;Start-Engine $script:credentials}else{Set-State 'Enter OTP' 'Check the SMS sent to the account holder'}}catch{Set-State 'Authorization failed' $_.Exception.Message}})
$Verify.Add_Click({$code=$OTP.Password;$OTP.Clear();try{if($code -notmatch '^\d{4,10}$'){throw 'OTP must contain 4-10 digits.'};$script:credentials=Parse-Credentials (Router-Request @{OTP=$code});$code=$null;Start-Engine $script:credentials}catch{$code=$null;Set-State 'Authorization failed' $_.Exception.Message}})
$Disconnect.Add_Click({Stop-Engine;Set-State 'Offline' 'Disconnected by user'})
$Call.Add_Click({try{$n=$Number.Text -replace '[^0-9+]','';if($n -match '^[6-9]\d{9}$'){$n='0'+$n};if(-not $n){throw 'Enter a valid number.'};Send-Engine ('DIAL`t'+(B64 $n))}catch{Set-State 'Call failed' $_.Exception.Message}})
$Answer.Add_Click({try{Send-Engine 'ANSWER'}catch{Set-State 'Call failed' $_.Exception.Message}});$Reject.Add_Click({try{Send-Engine 'REJECT'}catch{Set-State 'Call failed' $_.Exception.Message}});$Hangup.Add_Click({try{Send-Engine 'HANGUP'}catch{Set-State 'Call failed' $_.Exception.Message}});$Hold.Add_Click({try{Send-Engine $(if($script:held){'RESUME'}else{'HOLD'})}catch{Set-State 'Call failed' $_.Exception.Message}})
$window.Add_Closed({$heartbeat.Stop();Stop-Engine;$mutex.ReleaseMutex();$mutex.Dispose()});[void]$window.ShowDialog()
