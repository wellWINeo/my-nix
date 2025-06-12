userName:

let
  mediaGroupName = "media";
in
{
  users.users.${userName} = {
    isNormalUser = false;

    extraGroups = [ mediaGroupName ];
  };
}
