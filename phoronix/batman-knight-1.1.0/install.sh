#!/bin/bash
if which steam>/dev/null 2>&1 ;
then
	echo 0 > ~/install-exit-status
else
	echo "ERROR: Steam is not found on the system! This test profile needs a working Steam installation in the PATH"
	echo 2 > ~/install-exit-status
fi
HOME=$DEBUG_REAL_HOME steam steam://install/208650
unzip -o GFXSettings-Batman-Knight-1.zip
if ! command -v xmlstarlet &>/dev/null
then
  sudo apt install -y xmlstarlet
fi
if ! command -v xdotool &>/dev/null
then
  sudo apt install -y xdotool
fi
if ! command -v screen &>/dev/null
then
  sudo apt install -y screen
fi
xmlstarlet ed -L -u "//OPTION[@Name='Anti-Aliasing']/@Value" -v "0" \
                 -u "//OPTION[@Name='Interactive_Smoke']/@Value" -v "true" \
                 -u "//OPTION[@Name='Interactive_Paper_Debris']/@Value" -v "true" \
                 -u "//OPTION[@Name='Rain_FX']/@Value" -v "true" \
                 -u "//OPTION[@Name='Volumetric_Lighting']/@Value" -v "true" \
GFXSettings-High-BatmanArkhamKnight.xml
xmlstarlet ed -L -u "//OPTION[@Name='Anti-Aliasing']/@Value" -v "0" \
GFXSettings-Low-BatmanArkhamKnight.xml
echo "#!/bin/bash
rm -f \$DEBUG_REAL_HOME/.steam/steam/steamapps/common/Batman\ Arkham\ Knight/BmGame/Logs/benchmark.log
cp -f GFXSettings-\$3-BatmanArkhamKnight.xml \$DEBUG_REAL_HOME/.steam/steam/steamapps/compatdata/208650/pfx/drive_c/users/steamuser/My\ Documents/WB\ Games/Batman\ Arkham\ Knight/GFXSettings.BatmanArkhamKnight.xml
HOME=\$DEBUG_REAL_HOME steam -applaunch 208650 batentry?Area=UnderAce_A4,CityZ_08,CityZ_07,BatEntry__Benchmark_ChJ7_Bm?Chapters=0,A0,B0,C0,D0,E0,F0,G0,H0,I0,J7,K0,L0,M0,N0,O0,P0,Q0,R0,S0,T0,U0,V0,W0,X0,Y0,Z0,_F0,_G0,_K0,_M0?NoLevelOffsets?NoFadeIn?Start=BMAK_Benchmark_Start -NOLOGO ResX=\$1 ResY=\$2
sleep 30
until pgrep -x \"BatmanAK.exe\" > /dev/null; do
  sleep 2
done 
start=\$(date +%s)
while [ ! -f \$DEBUG_REAL_HOME/.steam/steam/steamapps/common/Batman\ Arkham\ Knight/BmGame/Logs/benchmark.log ]
do
  cur=\$(date +%s)
  time=\$((\$cur-\$start))
  if [ \$time -gt 30 ];
  then
    xdotool key KP_Enter
    start=\$(date +%s)
  fi
  sleep 2
done
killall -9 BatmanAK.e
killall -9 BatmanAK.exe
cat \$DEBUG_REAL_HOME/.steam/steam/steamapps/common/Batman\ Arkham\ Knight/BmGame/Logs/benchmark.log > \$LOG_FILE" > batman-knight
chmod +x batman-knight
