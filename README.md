# noderun.sh
This is a replacement for `knife ssh`, which no longer works as the ssh gem
embedded in our ancient version of `knife` doesn't do modern SSL ciphers.

This script acts as a wrapper around a `knife search node` command that
produces a list of nodes, and then uses the workstation `ssh` executable to
connect and run the specified command.

## Install
Clone this repository to your workstation. Put `noderun.sh` on your $PATH.

`noderun.sh -h` will display a usage message.

This utility was created with the help of ChatGPT and Claude.

Presented as-is, your mileage may vary, void where prohibited, may cause drowsiness, operating heavy machinery is fun, please fold, spindle, or mutilate.
