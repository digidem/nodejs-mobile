# Node.js for Mobile Apps

This is the main repository for *Node.js for Mobile Apps*, a toolkit for integrating Node.js into mobile applications.

## Resources for Newcomers

* [Frequently Asked Questions](https://github.com/nodejs-mobile/nodejs-mobile/blob/patches/docs/FAQ.md)
* [Discussions](https://github.com/nodejs-mobile/nodejs-mobile/discussions)
* [(Old) Website](https://code.janeasystems.com/nodejs-mobile)

The core library source code is in this repo. If you are looking for the *source code* for the plugins, you can find it at:

* [React Native plugin source repo](https://github.com/nodejs-mobile/nodejs-mobile-react-native)
* [Cordova plugin source repo](https://github.com/nodejs-mobile/nodejs-mobile-cordova)


## Project Goals

1. To provide the fixes necessary to run Node.js on mobile operating systems.
1. To investigate which features need to be added to Node.js in order to make it a useful tool for mobile app development.
1. To diverge as little as possible from nodejs/node, while fulfilling goals (1) and (2).

## Download

Binaries for Android and iOS are available at https://github.com/nodejs-mobile/nodejs-mobile/releases.

## Documentation

(Old) Documentation can be found on the [project website](https://code.janeasystems.com/nodejs-mobile). Sample code is available in the [(old) samples repo](https://github.com/janeasystems/nodejs-mobile-samples/).

***Disclaimer:***  documentation found in this repository is currently unchanged from parent repository and may only be applicable to upstream node.

## Versioning

This project does *NOT* follow SemVer; it tracks the upstream Node.js version it is built from.

A release is `A.B.C-R`, where `A.B.C` is the upstream Node.js version and `R` is the mobile revision — incremented for mobile-only rebuilds of that same upstream version, and reset to 0 when the upstream version changes. At runtime, `process.version` reports the plain upstream version (so version-parsing tools keep working) and `process.versions.mobile` reports the full `A.B.C-R`.

## Build Instructions

Please see [BUILDING.md](https://github.com/nodejs-mobile/nodejs-mobile/blob/patches/docs/BUILDING.md) on the project's `patches` branch.

## Running tests

Please see [TESTING.md](https://github.com/nodejs-mobile/nodejs-mobile/blob/patches/docs/TESTING.md) on the project's `patches` branch.

## Contributing

This source tree is generated from the project's `patches` branch, which holds the mobile patch series, the tooling, and all of the project's documentation. See [CONTRIBUTING](https://github.com/nodejs-mobile/nodejs-mobile/blob/patches/docs/CONTRIBUTING.md).
