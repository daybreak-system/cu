wget https://github.com/mtoyoda/sl/archive/refs/tags/5.02.tar.gz
tar -xvzf 5.02.tar.gz
cd sl-5.02
clang -Wall -o sl sl.c -lncurses
chmod +x sl
mkdir -p $1/usr/bin
cp ./sl $1/usr/bin/sl
