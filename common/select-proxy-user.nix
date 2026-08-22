hostname: users:
let
  matches = builtins.filter (u: (u.name or "") == hostname) users;
  count = builtins.length matches;
in
if count == 1 then
  builtins.head matches
else
  throw "Expected exactly one singBoxUsers entry named '${hostname}', found ${builtins.toString count}"
