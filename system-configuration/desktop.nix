{
  lib,
  pkgs,
  config,
  ...
}:
{
  # very minimal X server setup
  services.xserver.enable = true;
  services.xserver.windowManager.jwm.enable = true;
  services.displayManager.defaultSession = lib.mkDefault "none+jwm";

  # run xserver automatically after autologin
  services.greetd = {
    enable = true;
    settings = {
      default_session.command = "${pkgs.greetd}/bin/agreety --cmd ${pkgs.bashInteractive}/bin/bash";
      initial_session = {
        user = "root";
        command = "startx";
      };
    };
  };

  # configure JWM and xterm
  services.xserver.displayManager.startx = {
    enable = true;
    generateScript = true;
    extraCommands = ''
      cat <<EOF > $HOME/.jwmrc
      <?xml version="1.0"?>
      <JWM>
        <Desktops width="1" height="1">
          <Desktop>
            <Background type="image">
              ${pkgs.callPackage ./background {
                inherit (config.system.image) version;
              }}
            </Background>
          </Desktop>
        </Desktops>

        <RootMenu onroot="12">
          <Program icon="utilities-terminal" label="Terminal">xterm</Program>
          <Separator/>
          <Restart label="Restart" icon="reload"/>
          <Exit label="Exit" confirm="true" icon="exit"/>
        </RootMenu>

        <Tray x="0" y="-1" autohide="off" delay="1000">
          <TrayButton label="Appliance">root:1</TrayButton>
          <Spacer width="2"/>
          <Pager labeled="true"/>
          <TaskList maxwidth="256"/>
          <Dock/>
          <Clock format="%l:%M %p"><Button mask="123">exec:xclock</Button></Clock>
        </Tray>

      </JWM>

      EOF

      cat <<EOF > $HOME/.Xresources
      xterm*background: black
      xterm*foreground: white
      xterm*faceName: DejaVu Sans Mono
      xterm*faceSize: 15
      EOF

      xrdb $HOME/.Xresources
    '';
  };

  # desktop size reduction
  hardware.graphics.enable = false;
  services.speechd.enable = false;
  services.pipewire.enable = false;
  services.libinput.enable = false;

  xdg.autostart.enable = lib.mkForce false;
  xdg.menus.enable = lib.mkForce false;
  xdg.mime.enable = lib.mkForce false;
  xdg.terminal-exec.enable = false;

  fonts.enableDefaultPackages = false;
  fonts.packages = lib.mkForce [ pkgs.dejavu_fonts ];

  services.xserver.desktopManager.session = lib.mkForce [
    {
      name = "none";
      bgSupport = true; # if this bit is false we pull in a lot of deps
      start = "";
    }
  ];

  nixpkgs.overlays = [
    (_final: prev: {
      xdg-utils = prev.hello; # cheap fake xdg-utils that don't pull in Perl etc.
      imlib2Full = prev.imlib2Full.override { jxlSupport = false; };
    })
  ];

}
