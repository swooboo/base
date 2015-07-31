#!/bin/sh
SEMABUILD_PWD=`pwd`
SEMABUILD_BUILD="${HOME}/build"
SEMABUILD_DIR="${SEMABUILD_BUILD}/${BRANCH_NAME}"
SEMABUILD_SCP='scp -BC -o StrictHostKeyChecking=no'
SEMABUILD_TARGET='pi@swooboo.com:/home/pi/semaphore/'
SEMABUILD_APT='DEBIAN_FRONTEND=noninteractive apt-get'
SEMABUILD_SOURCE="http://swooboo.com/files"
SEMABUILD_MODULES=`cat "${SEMABUILD_PWD}/.gitmodules" | grep '\[submodule' | sed -e 's/^.submodule..//;s/..$//' | tr "\n" " " | sed -e 's/ $//'`
SEMABUILD_ALLMODS="base ${SEMABUILD_MODULES}"
SEMABUILD_DEPLOY="false"

semabuild_setup() {
    echo "setting up ${BRANCH_NAME}..."
    rm -rf "${SEMABUILD_DIR}"
    rm -rf "${SEMABUILD_PWD}/data"
    mkdir -pv "${SEMABUILD_DIR}" || return 1
    return 0
}

semabuild_archive() {
    echo "archiving ${BRANCH_NAME}..."
    # windows
    pushd "${SEMABUILD_DIR}/windows" || return 1
    #cp -fv "${SEMABUILD_PWD}/redeclipse.bat" "${SEMABUILD_DIR}/windows/redeclipse.bat"
    #cp -fv "${SEMABUILD_PWD}/bin/update.bat" "${SEMABUILD_DIR}/windows/bin/update.bat"
    zip -r "${SEMABUILD_DIR}/windows.zip" . || return 1
    popd
    # linux
    pushd "${SEMABUILD_DIR}/linux" || return 1
    #cp -fv "${SEMABUILD_PWD}/redeclipse.sh" "${SEMABUILD_DIR}/linux/redeclipse.sh"
    #cp -fv "${SEMABUILD_PWD}/bin/update.sh" "${SEMABUILD_DIR}/linux/bin/update.sh"
    tar -zcvf "${SEMABUILD_DIR}/linux.tar.gz" . || return 1
    popd
    # cleanup
    rm -rf "${SEMABUILD_DIR}/windows" "${SEMABUILD_DIR}/linux" || return 1
    SEMABUILD_DEPLOY="true"
    return 0
}

semabuild_build() {
    echo "building ${BRANCH_NAME}..."
    sudo dpkg --add-architecture i386 || return 1
    sudo ${SEMABUILD_APT} update || return 1
    sudo ${SEMABUILD_APT} -fy install build-essential multiarch-support gcc-multilib g++-multilib zlib1g-dev libsdl-mixer1.2-dev libsdl-image1.2-dev binutils-mingw-w64 g++-mingw-w64 || return 1
    make PLATFORM=crossmingw64 PLATFORM_BIN=amd64 INSTDIR=${SEMABUILD_DIR}/windows/bin/amd64 CFLAGS=-m64 CXXFLAGS=-m64 LDFLAGS=-m64 -C src clean install || return 1
    make PLATFORM=crossmingw32 PLATFORM_BIN=x86 INSTDIR=${SEMABUILD_DIR}/windows/bin/x86 CFLAGS=-m32 CXXFLAGS=-m32 LDFLAGS=-m32 -C src clean install || return 1
    make PLATFORM=linux64 PLATFORM_BIN=amd64 INSTDIR=${SEMABUILD_DIR}/linux/bin/amd64 CFLAGS=-m64 CXXFLAGS=-m64 LDFLAGS=-m64 -C src clean install || return 1
    sudo apt-get -o Dpkg::Options::="--force-overwrite" -fy install zlib1g-dev:i386 libsdl1.2-dev:i386 libsdl-mixer1.2-dev:i386 libsdl-image1.2-dev:i386 libpng12-dev:i386 libcaca-dev:i386 libglu1-mesa-dev:i386 libgl1-mesa-dev:i386 || sudo apt-get -o Dpkg::Options::="--force-overwrite" -fy install || return 1
    sudo apt-get -o Dpkg::Options::="--force-overwrite" -fy install gcc:i386 g++:i386 || sudo apt-get -o Dpkg::Options::="--force-overwrite" -fy install || return 1
    make PLATFORM=linux32 PLATFORM_BIN=x86 INSTDIR=${SEMABUILD_DIR}/linux/bin/x86 CFLAGS=-m32 CXXFLAGS=-m32 LDFLAGS=-m32 -C src clean install || return 1
    return 0
}

semabuild_integrate() {
    for i in ${SEMABUILD_ALLMODS}; do
        if [ "${i}" = "base" ]; then
            SEMABUILD_MODDIR="${SEMABUILD_PWD}"
        else
            SEMABUILD_MODDIR="${SEMABUILD_PWD}/data/${i}"
            echo "module ${i} updating.."
            git submodule init "data/${i}"
            git submodule update "data/${i}"
        fi
        pushd "${SEMABUILD_MODDIR}" || return 1
        echo "module ${i} processing.."
        SEMABUILD_HASH=`git rev-parse HEAD` || return 1
        SEMABUILD_LAST=`curl --fail --silent "${SEMABUILD_SOURCE}/${BRANCH_NAME}/${i}.txt"`
        echo "module ${i} compare: ${SEMABUILD_LAST} -> ${SEMABUILD_HASH}"
        if [ -n "${SEMABUILD_HASH}" ] && [ "${SEMABUILD_HASH}" != "${SEMABUILD_LAST}" ]; then
            echo "module ${i} updated, syncing.."
            echo "${SEMABUILD_HASH}" > "${SEMABUILD_DIR}/${i}.txt"
            SEMABUILD_DEPLOY="true"
            if [ "${i}" = "base" ]; then
                echo "module ${i} checking for source modifications.."
                SEMABUILD_BINS=`curl --fail --silent "${SEMABUILD_SOURCE}/${BRANCH_NAME}/bins.txt"` || return 1
                SEMABUILD_CHANGES=`git diff --name-only HEAD ${SEMABUILD_BINS} -- src | egrep '\.h$|\.c$|\.cpp$|Makefile$'`
                if [ -n "${SEMABUILD_CHANGES}" ]; then
                    echo "module ${i} has modified source files:"
                    echo "${SEMABUILD_CHANGES}"
                    semabuild_build || return 1
                    semabuild_archive || return 1
                    echo "binary archive updated, syncing: ${SEMABUILD_HASH} -> ${SEMABUILD_BINS}"
                    echo "${SEMABUILD_HASH}" > "${SEMABUILD_DIR}/bins.txt"
                fi
            fi
        fi
        popd
    done
    return 0
}

semabuild_process() {
    if [ "${BRANCH_NAME}" = master ] || [ "${BRANCH_NAME}" = stable ] || [ "${BRANCH_NAME}" = "my-semaphore" ]; then
        semabuild_integrate || return 1
    else
        semabuild_build || return 1
    fi
    return 0
}

semabuild_deploy() {
    echo "deploying ${BRANCH_NAME}..."
    echo "${SEMABUILD_ALLMODS}" > "${SEMABUILD_DIR}/mods.txt"
    pushd "${SEMABUILD_BUILD}" || return 1
    ${SEMABUILD_SCP} -r "${BRANCH_NAME}" "${SEMABUILD_TARGET}" || return 1
    return 0
}

semabuild_setup || exit 1
semabuild_process || exit 1
if [ "${SEMABUILD_DEPLOY}" = "true" ]; then
    semabuild_deploy || exit 1
fi
echo "done."
