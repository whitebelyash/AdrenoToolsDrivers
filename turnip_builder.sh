#!/bin/bash -e

#Define variables
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'
deps="git meson ninja patchelf unzip curl pip flex bison zip glslang glslangValidator"
workdir="$(pwd)/turnip_workdir"
base_workdir="$(pwd)"
magiskdir="$workdir/turnip_module"
ndkver="android-ndk-r29"
ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
sdkver="34"
mesasrc="https://github.com/whitebelyash/mesa-unified"
srcfolder="mesa"

clear

#There are 4 functions here, simply comment to disable.
#You can insert your own function and make a pull request.
run_all(){
	echo "====== Begin building TU V$BUILD_VERSION! ======"
	echo "Current directory: $base_workdir"
	check_deps
	prepare_workdir
	# This has path slash in the branch name and thus needs some workarounds
	build_lib_for_android turnip/26.2 turnip
	build_lib_for_android turnip/26.2 turnip-sync apply
	#build_lib_for_android gen8-yuck
}

check_deps(){
	echo "Checking system for required Dependencies ..."
		for deps_chk in $deps;
			do
				sleep 0.25
				if command -v "$deps_chk" >/dev/null 2>&1 ; then
					echo -e "$green - $deps_chk found $nocolor"
				else
					echo -e "$red - $deps_chk not found, can't countinue. $nocolor"
					deps_missing=1
				fi;
			done

		if [ "$deps_missing" == "1" ]
			then echo "Please install missing dependencies" && exit 1
		fi

	echo "Installing python Mako dependency (if missing) ..." $'\n'
		pip install mako &> /dev/null
}

prepare_workdir(){
	echo "Preparing work directory ..." $'\n'
		mkdir -p "$workdir" && cd "$_"

	echo "Downloading android-ndk from google server ..." $'\n'
		curl https://dl.google.com/android/repository/"$ndkver"-linux.zip --output "$ndkver"-linux.zip &> /dev/null
	echo "Exracting android-ndk ..." $'\n'
		unzip "$ndkver"-linux.zip &> /dev/null

	echo "Downloading mesa source ..." $'\n'
		git clone $mesasrc --depth=1 --no-single-branch $srcfolder
		cd $srcfolder
}

apply_patch() {
	echo "Applying patch $1"
	if ! git apply --check $1; then
			echo "Failed to apply $1!"
			exit 1
		fi
    	git apply $1
}

# $1 - real branch, $2 - escaped branch name
build_lib_for_android(){
	echo "==== Building Mesa on $1 branch ===="
	git checkout --force origin/$1
	if [[ "$3" == "apply" ]]; then
		echo "Applying patches"
		for patch in $base_workdir/patches/*; do
			apply_patch $patch
		done
	fi
	#Workaround for using Clang as c compiler instead of GCC
	mkdir -p "$workdir/bin"
	ln -sf "$ndk/clang" "$workdir/bin/cc"
	ln -sf "$ndk/clang++" "$workdir/bin/c++"
	export PATH="$workdir/bin:$ndk:$PATH"
	export CC=clang
	export CXX=clang++
	export AR=llvm-ar
	export RANLIB=llvm-ranlib
	export STRIP=llvm-strip
	export OBJDUMP=llvm-objdump
	export OBJCOPY=llvm-objcopy
	export LDFLAGS="-fuse-ld=lld"

	echo "Generating build files ..." $'\n'
		cat <<EOF >"android-aarch64.txt"
[binaries]
ar = '$ndk/llvm-ar'
c = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang']
cpp = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = '$ndk/ld.lld'
cpp_ld = '$ndk/ld.lld'
strip = '$ndk/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$ndk/pkg-config', '/usr/bin/pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

		cat <<EOF >"native.txt"
[build_machine]
c = ['ccache', 'clang']
cpp = ['ccache', 'clang++']
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'ld.lld'
cpp_ld = 'ld.lld'
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

		meson setup build-android-aarch64 \
			--cross-file "android-aarch64.txt" \
			--native-file "native.txt" \
			--prefix /tmp/turnip-$2 \
			-Dbuildtype=release \
			-Dstrip=true \
			-Dplatforms=android \
			-Dvideo-codecs= \
			-Dplatform-sdk-version="$sdkver" \
			-Dandroid-stub=true \
			-Dgallium-drivers= \
			-Dvulkan-drivers=freedreno \
			-Dvulkan-beta=true \
			-Dfreedreno-kmds=kgsl \
			-Degl=disabled \
			-Dplatform-sdk-version=36 \
			-Dandroid-libbacktrace=disabled \
			--reconfigure

	echo "Compiling build files ..." $'\n'
		ninja -C build-android-aarch64 install

	if ! [ -a /tmp/turnip-$2/lib/libvulkan_freedreno.so ]; then
		echo -e "$red Build failed! $nocolor" && exit 1
	fi
	echo "Making the archive"
	cd /tmp/turnip-$2/lib
	cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "Stable Turnip v$BUILD_VERSION",
  "description": "Mesa 26.2 Turnip driver with additional GPU support. Built from $1 branch",
  "author": "whitebelyash",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan 1.4.335",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF
zip /tmp/stable-$2-V$BUILD_VERSION.zip libvulkan_freedreno.so meta.json
cd -
if ! [ -a /tmp/stable-$2-V$BUILD_VERSION.zip ]; then
	echo -e "$red Failed to pack the archive! $nocolor"
fi
}

run_all
