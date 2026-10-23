#!/bin/bash
# 清理 .profile 里此前写入的 riscv32 PATH 行（可能为展开错误的坏行），
# 再追加正确的字面 $PATH 形式。
sed -i '/toolchains\/riscv32-musl/d' ~/.profile
echo 'export PATH=$HOME/toolchains/riscv32-musl/cc-riscv32-cfg5-musl-20211008-elf/bin:$PATH' >> ~/.profile
tail -1 ~/.profile
