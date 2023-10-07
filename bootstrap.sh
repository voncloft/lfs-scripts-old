#!/bin/sh -e	

_buildtoolchain() {
	if [ "$(id -u)" = 0 ]; then
		echo "temporary toolchain need to build as regular user"
		exit 1
	fi

	export BOOTSTRAP=1
	export PATH=$TOOLS/bin:$PATH
	export LFS_TGT=x86_64-lfs-linux-gnu
	export LFS_TGT32=i686-lfs-linux-gnu
	
	mkdir -p ${LFS}${TOOLS} $sourcedir
	rm -f $TOOLS
	ln -sf ${LFS}${TOOLS} $TOOLS
	
	echo "
export MAKEFLAGS=-j$(nproc)

PKGMK_SOURCE_DIR=$sourcedir
PKGMK_PACKAGE_DIR=/tmp/lfs-pkg

. $PWD/files/pkgmk.bootstrap
" > /tmp/bootstrap.conf

	if [ ! "$(command -v pkgmk)" ]; then
		if [ ! -f $sourcedir/pkgutils-5.40.10.tar.xz ]; then
			curl -o $sourcedir/pkgutils-5.40.10.tar.xz https://crux.nu/files/pkgutils-5.40.10.tar.xz
		fi
		rm -rf /tmp/pkgutils-5.40.10
		tar -xf $sourcedir/pkgutils-5.40.10.tar.xz -C /tmp
		sed -i -e 's/ --static//' -e 's/ -static//' /tmp/pkgutils-5.40.10/Makefile
		make -C /tmp/pkgutils-5.40.10
		make -C /tmp/pkgutils-5.40.10 BINDIR=$TOOLS/bin MANDIR=$TOOLS/man ETCDIR=$TOOLS/etc install
	fi
	
	for i in $toolchainpkg; do
		[ -f $TOOLS/$i ] && continue
		export tcpkg="$i"
		cd core/${i%-pass*}
		mkdir -p /tmp/lfs-pkg
		pkgmk -d -if -cf /tmp/bootstrap.conf
		rm -rf /tmp/lfs-pkg
		cd - >/dev/null 2>&1
		touch $TOOLS/$i
		unset tcpkg
	done
	rm -f /tmp/bootstrap.conf
	
	TMPPWD=$PWD
	cd $LFS
	rm -f "$TMPPWD/toolchain.tar.xz"
	XZ_DEFAULTS='-T0' tar -cvJpf "$TMPPWD/toolchain.tar.xz" *
	cd $TMPPWD
	
	echo
	echo "toolchain build completed"
}

_compressrootfs() {	
	TMPPWD=$PWD
	cd $LFS
	rm -f "$TMPPWD/lfs-rootfs.tar.xz"
	XZ_DEFAULTS='-T0' tar \
		--exclude='./var/lib/pkg/rejected' \
		--exclude=".$TOOLS" \
		--exclude='./tmp/*' \
		--exclude='./dev/*' \
		--exclude='./sys/*' \
		--exclude='./proc/*' \
		--exclude='./run/*' \
		-cvJpf "$TMPPWD/lfs-rootfs.tar.xz" .
	cd $TMPPWD
	
	echo
	echo "base rootfs is compressed: $TMPPWD/lfs-rootfs.tar.xz"
}

_buildbase() {
	if [ "$(id -u)" != 0 ]; then
		echo "base need to build as root"
		exit 1
	fi
	if [ ! -f $LFS/var/lib/pkg/db ]; then
		mkdir -pv $LFS/bin $LFS/usr/lib $LFS/usr/bin $LFS/etc $LFS/dev || true
		for i in bash cat chmod dd echo ln mkdir pwd rm stty; do
			ln -svf $TOOLS/bin/$i $LFS/bin
		done
		for i in env install perl printf touch; do
			ln -svf $TOOLS/bin/$i $LFS/usr/bin
		done
		ln -svf $TOOLS/lib/libgcc_s.so $TOOLS/lib/libgcc_s.so.1 $LFS/usr/lib
		ln -svf $TOOLS/lib/libstdc++.a $TOOLS/lib/libstdc++.so $TOOLS/lib/libstdc++.so.6 $LFS/usr/lib
		ln -svf bash $LFS/bin/sh
		ln -svf /proc/self/mounts $LFS/etc/mtab
		
		mknod -m 600 $LFS/dev/console c 5 1
		mknod -m 666 $LFS/dev/null c 1 3

		cat core/aaa_filesystem/passwd > $LFS/etc/passwd
		cat core/aaa_filesystem/group > $LFS/etc/group

		# pkgutils
		mkdir -p $LFS/var/lib/pkg
		touch $LFS/var/lib/pkg/db
		
		# package and source
		mkdir -p $LFS/tmp/src
		mkdir -p $LFS/tmp/pkg
	fi
	
	# core ports
	rm -rf $LFS/usr/ports/core
	mkdir -p $LFS/usr/ports/core
	cp -r core/* $LFS/usr/ports/core
	
	# xpkg
	echo 'repodir /usr/ports/core' > $LFS/etc/xpkg.conf
	cp core/xpkg/xpkg $TOOLS/bin
	chmod +x $TOOLS/bin/xpkg
	
	# pkgmk
	mkdir -p $LFS/var/lib/pkgmk
	cp core/pkgutils/extension $LFS/var/lib/pkgmk
	cp core/pkgutils/pkgadd.conf $LFS/etc
	echo '
export CFLAGS="-O2 -march=x86-64 -pipe"
export CXXFLAGS="${CFLAGS}"

export JOBS=$(nproc)
export MAKEFLAGS="-j $JOBS"

PKGMK_SOURCE_DIR="/tmp/src"
PKGMK_PACKAGE_DIR="/tmp/pkg"
PKGMK_WORK_DIR="/tmp/pkgmk-$name"

. /var/lib/pkgmk/extension' > $LFS/tmp/pkgmk.conf
	
	if [ "$1" = rebuild ]; then
		LFSPATH=/bin:/usr/bin:/sbin:/usr/sbin
		_xpkg_opt="upgrade -fr"
	else
		LFSPATH=/bin:/usr/bin:/sbin:/usr/sbin:$TOOLS/bin
		_xpkg_opt="add"
	fi
	
	mountfs
	for i in $basepkg; do
		if [ "$1" != rebuild ]; then
			pkginfo -i -r $LFS | awk '{print $1}' | grep -qx $i && continue
			unset _force
			case $i in
				aaa_filesystem|gcc|bash|dash|perl|coreutils|pkgutils|xpkg) _force=-f;;
			esac
		fi
		chroot $LFS env -i PATH=$LFSPATH xpkg $_xpkg_opt $i -y $_force -if -nd -cf /tmp/pkgmk.conf || { umountfs; exit 1; }
		if [ "$1" != rebuild ]; then
			case $i in
				glibc) cat << EOF > $LFS/tmp/glibc-postinstall
#!/bin/sh
[ -f $TOOLS/bin/ld-old ] && exit 0
mv -v $TOOLS/bin/ld $TOOLS/bin/ld-old
mv -v $TOOLS/$(uname -m)-pc-linux-gnu/bin/ld $TOOLS/$(uname -m)-pc-linux-gnu/bin/ld-old
mv -v $TOOLS/bin/ld-new $TOOLS/bin/ld
ln -sv $TOOLS/bin/ld $TOOLS/$(uname -m)-pc-linux-gnu/bin/ld
gcc -dumpspecs | sed -e "s@$TOOLS@@g" -e "/\*startfile_prefix_spec:/{n;s@.*@/usr/lib/ @}" -e '/\*cpp:/{n;s@\$@ -isystem /usr/include@}' > \$(dirname \$(gcc --print-libgcc-file-name))/specs
echo 'int main(){}' > dummy.c
cc dummy.c -v -Wl,--verbose > dummy.log 2>&1
readelf -l a.out | grep ': /lib' > /tmp/adjusttoolchainresult
grep -o '/usr/lib.*/crt[1in].*succeeded' dummy.log >> /tmp/adjusttoolchainresult
grep -B1 '^ /usr/include' dummy.log >> /tmp/adjusttoolchainresult
grep 'SEARCH.*/usr/lib' dummy.log |sed 's|; |\n|g' >> /tmp/adjusttoolchainresult
grep "/lib.*/libc.so.6 " dummy.log >> /tmp/adjusttoolchainresult
grep found dummy.log >> /tmp/adjusttoolchainresult
rm -v dummy.c a.out dummy.log
EOF
				chroot $LFS env -i PATH=$LFSPATH sh /tmp/glibc-postinstall
				rm -f $LFS/tmp/glibc-postinstall
				;;
			esac
		fi
	done
	umountfs
	
	echo
	echo "base system build completed"
}

mountfs() {
	# unmount first incase already mounted
	umountfs
	mkdir -p $LFS/dev $LFS/run $LFS/proc $LFS/sys
	mount --bind /dev $LFS/dev
	mount -t devpts devpts $LFS/dev/pts -o gid=5,mode=620
	mount -t proc proc $LFS/proc
	mount -t sysfs sysfs $LFS/sys
	mount -t tmpfs tmpfs $LFS/run
	if [ -h $LFS/dev/shm ]; then
	  mkdir -p $LFS/$(readlink $LFS/dev/shm)
	fi
	mkdir -p $LFS/tmp/src $LFS/tmp/pkg
	mount --bind $sourcedir $LFS/tmp/src
	mount --bind $packagedir $LFS/tmp/pkg
}

umountfs() {
	unmount $LFS/dev/pts
	unmount $LFS/dev
	unmount $LFS/run
	unmount $LFS/proc
	unmount $LFS/sys
	unmount $LFS/tmp/pkg
	unmount $LFS/tmp/src
}

unmount() {
	while true; do
		mountpoint -q $1 || break
		umount $1 2>/dev/null
	done
}

export LFS=/tmp/lfs-rootfs
export TOOLS=/tmp/lfs-tools
export LC_ALL=C

toolchainpkg="binutils-pass1 gmp mpfr mpc gcc-pass1 linux-headers glibc gcc-pass2 binutils-pass2 gcc-pass3 m4
	ncurses bash bison bzip2 coreutils diffutils file findutils gawk gettext grep gzip make patch perl python
	sed tar texinfo xz openssl ca-certificates curl libarchive"
	
basepkg="aaa_filesystem linux-headers man-pages glibc tzdata zlib bzip2 xz file ncurses readline m4 bc binutils
	gmp mpfr mpc attr acl shadow gcc pkgconf libcap sed psmisc iana-etc bison flex pcre2 grep bash dash
	libtool gdbm gperf expat inetutils perl perl-xml-parser intltool autoconf automake openssl kmod gettext elfutils
	libffi sqlite python coreutils check diffutils gawk findutils groff less gzip zstd iptables libtirpc iproute2 kbd
	libpipeline make patch man-db tar texinfo vim procps-ng util-linux e2fsprogs sysklogd eudev which
	libarchive ca-certificates curl pkgutils xpkg"

sourcedir="$PWD/sources"
packagedir="$PWD/packages"

if [ ! "$1" ]; then	
	cat << EOF
Usage:
  $0 <options>
  
Options:
  1  build temporary toolchain
  2  build base system (using temporary toolchain)
  3  rebuild base system (using final system toolchain itself)
  4  compress base rootfs
EOF
	exit 0
fi
	
case $1 in
	1) _buildtoolchain;;
	2) _buildbase;;
	3) _buildbase rebuild;;
	4) _compressrootfs;;
esac

exit 0
