with builtins;
let 
  secrets = fromJSON (readFile ./secrets.json); 
in secrets