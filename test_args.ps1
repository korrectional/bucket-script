
Write-Output "Args count: $($args.Count)"
for ($i = 0; $i -lt $args.Count; $i++) {
    Write-Output "Arg $i: $($args[$i])"
}

