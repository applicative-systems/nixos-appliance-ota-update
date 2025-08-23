{
  runCommand,
  imagemagick,
  version ? "1",
}:

let
  env = {
    nativeBuildInputs = [
      (imagemagick.override { ghostscriptSupport = true; })
    ];
  };
in

runCommand "background.jpg" env ''
  w=1280
  h=800
  logo=${./nixcademy-horizontal-color.svg}
  logoWidth=$((w * 9 / 10))
  textOffset=$((h * 3 / 4))

  export HOME="$PWD" # will try to create .cache/fontconfig

  set -x
  magick \
    -size "''${w}x''${h}" xc:white \
    \( "$logo" -resize "$logoWidth"x -gravity center \) -gravity center -composite \
    -fill black -pointsize 100 \
    -gravity center -annotate +0+300 "Appliance Version ${version}" \
    "$out"
''
