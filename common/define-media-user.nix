userName:

let
  mediaGroupName = "media";
in
{
  users.users.${userName} = {
    isNormalUser = false;
    isSystemUser = true;
    extraGroups = [ mediaGroupName ];
  };
}
