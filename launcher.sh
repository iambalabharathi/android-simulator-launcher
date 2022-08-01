#!/bin/sh

simulatorLaunchRetries=300 # Default launch check retry count.
pollTimeInSeconds=2 # Poll time between retry

for i in "$@"; do
    case $i in
        --apiLevel=*)
            apiLevel="${i#*=}"
            shift # past argument=value
            ;;
        --sdkTarget=*)
            sdkTarget="${i#*=}"
            shift # past argument=value
            ;;
        --sdkCpuArch=*)
            sdkCpuArch="${i#*=}"
            shift # past argument=value
            ;;
        --simulatorLaunchRetries=*)
            simulatorLaunchRetries="${i#*=}"
            shift # past argument=value
            ;;
        --pollTimeInSeconds=*)
            pollTimeInSeconds="${i#*=}"
            shift # past argument=value
            ;;
        --apk=*)
            apk="${i#*=}"
            shift # past argument=value
            ;;
        --default)
            DEFAULT=YES
            shift # past argument with no value
            ;;
        -*|--*)
            echo "Unknown option $i"
            exit 1
            ;;
        *)
            ;;
    esac
done

function inputF() {
    echo "❌ No $1 specified. Check your cmd\n📝 Example values: [$2]\n💡 Run sdkmanager --list command on your machine to see the full list."
}

if [[ -z "$apiLevel" ]]; then
    inputF "--apiLevel" "33,32,31"
    exit 0
fi

if [[ -z "$sdkTarget" ]]; then
    inputF "--sdkTarget" "google_apis, default"
    exit 0
fi

if [[ -z "$sdkCpuArch" ]]; then
    inputF "--sdkCpuArch" "x86,x86_64,arm64-v8a (for M1 mac)"
    exit 0
fi

cmdlineToolsLinux='https://dl.google.com/android/repository/commandlinetools-linux-8512546_latest.zip'
cmdlineToolsMac='https://dl.google.com/android/repository/commandlinetools-mac-8512546_latest.zip'
androidLicenses="$(pwd)/.github/actions/android-simulator/licenses"

buildToolsVersion=33.0.0
channel=0

androidSimulatorName="api-$apiLevel-$(uuidgen)"

unameOut="$(uname -s)"
case "${unameOut}" in
    Linux*)
        os=linux
        downloadURL=$cmdlineToolsLinux
        emulatorOpts="-accel off"
        ;;
    Darwin*)
        os=mac
        downloadURL=$cmdlineToolsMac
        emulatorOpts=""
        ;;
    *) 
        echo "Script is not implemented for this Operating system :${unameOut}"
        exit 0
esac

export ANDROID_HOME="$(pwd)/Android/SDK"
export ANDROID_SDK_ROOT=$ANDROID_HOME
export ANDROID_SDK_HOME=$ANDROID_HOME
export ANDROID_AVD_HOME=$ANDROID_HOME/.android/avd

echo "----------------------------------------------------------------"
echo "🖥 Operating System       : $os"
echo "🛠 SDK download URL       : $downloadURL"
echo "🏠 SDK home               : $ANDROID_HOME"
echo "🏠 AVD home               : $ANDROID_AVD_HOME"
echo "🛠 Build tools version    : $buildToolsVersion"
echo "🛠 SDK download channel   : stable"
echo "🛠 Api level              : $apiLevel"
echo "🛠 SDK Target             : $sdkTarget"
echo "🛠 SDK CPU arch.          : $sdkCpuArch"
echo "🛠 Device name            : $androidSimulatorName"
echo "🛠 Launch Retries (max)   : $simulatorLaunchRetries"
echo "----------------------------------------------------------------"

mkdir -p $ANDROID_HOME
sudo chown $USER:$USER ${ANDROID_SDK_ROOT} -R

# Check if commandline tools already exists in the path.
cmdlineTools="$ANDROID_SDK_ROOT/cmdline-tools"
if [ ! -d "${cmdlineTools}" ] 
then
    echo "::group::⬇️ Download commandline tools"
    echo "Download URL => $downloadURL"
    curl "${downloadURL}" >> tools.zip
    unzip tools.zip && rm tools.zip
    mkdir -p "${cmdlineTools}/latest"
    mv cmdline-tools/* "${cmdlineTools}/latest"
    echo "::endgroup::"
fi

export PATH="$cmdlineTools/latest:$cmdlineTools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_AVD_HOME:$PATH"

sdkmanager="$cmdlineTools/latest/bin/sdkmanager"

echo "::group::🛠 Copy Android SDK licenses"
mkdir -p $ANDROID_SDK_ROOT/licenses
cp -r $androidLicenses/* $ANDROID_SDK_ROOT/licenses
echo "::endgroup::"

echo "::group::🛠 Install build tools"
$sdkmanager --install "build-tools;${buildToolsVersion}" platform-tools "platforms;android-${apiLevel}" > /dev/null
echo "::endgroup::"

echo "::group::🛠 Install emulator tools"
$sdkmanager --install emulator --channel=0 > /dev/null
echo "::endgroup::"

echo "::group::🛠 Install Android system images"
$sdkmanager --install "system-images;android-${apiLevel};${sdkTarget};${sdkCpuArch}" --channel="${channel}" > /dev/null
echo "::endgroup::"

echo "::group::🛠 Create AVD"
echo no | avdmanager create avd --force -n "${androidSimulatorName}" --abi "${sdkTarget}/${sdkCpuArch}" --package "system-images;android-${apiLevel};${sdkTarget};${sdkCpuArch}"
echo "::endgroup::"

echo "::group::🚀 Start AVD"
emulator="$ANDROID_SDK_ROOT/emulator/emulator"
$emulator -list-avds

avdDir="$ANDROID_AVD_HOME/${androidSimulatorName}.avd"
avdConfigFile="$avdDir/config.ini"

printf 'hw.cpu.ncore = 2\n' >> $avdConfigFile
printf 'hw.keyboard = yes\n' >> $avdConfigFile
printf 'hw.sdCard = yes\n' >> $avdConfigFile
printf 'sdcard.size = 512M\n' >> $avdConfigFile
printf 'hw.ramSize = 3000\n' >> $avdConfigFile

$emulator -avd $androidSimulatorName $emulatorOpts &
echo "::endgroup::"

echo "::group::🧪 Wait for AVD status to be booted"
try=1
booted=false

while ! $booted; do
    bootState="$(adb shell getprop sys.boot_completed)"
    if [[ $bootState == "1" ]]; then
        echo "✅ AVD booted"
        break
    else
        echo "AVD status [Not booted, Orginal Status ($bootState)], Attempt ($try/$simulatorLaunchRetries)"
        if [[ $try == $simulatorLaunchRetries ]]; then
            echo "❌ AVD launch failure. Waited for 600 seconds"
            exit 1
        else
            try=$((try+1))
            sleep $pollTimeInSeconds
        fi
    fi
done
echo "::endgroup::"

# Check if app needs to be installed after launch
if [ ! -z "$apk" ];then
    echo "::group::🛠 Install App"
    adbInstallOutput="$(adb install $apk)"
    if [[ "$adbInstallOutput" == *"Success"* ]]; then
        echo "✅ App installation successful"
    else
        echo "❌ App installation failed"
        exit 1
    fi
    echo "::endgroup::"
fi
