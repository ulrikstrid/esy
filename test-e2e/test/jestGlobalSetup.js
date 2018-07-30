// @flow

const fs = require('fs-extra');
const os = require('os');
const path = require('path');
const childProcess = require('child_process');
const {promisify} = require('util');
const promiseExec = promisify(childProcess.exec);

const ESYCOMMAND = require.resolve('../../bin/esy');

const testPath = path.join(os.homedir(), '.esytest');
const sandboxPath = path.join(testPath, 'sandbox');
const esyPrefixPath = path.join(testPath, 'esy');
const ocamlPackagePath = path.join(testPath, 'ocaml');

async function mkdirOrIgnore(path) {
  try {
    await fs.mkdir(path);
  } catch (e) {
    // doesn't matter if it exists
  }
}

function esy(args, options) {
  options = options || {};

  return promiseExec(`${ESYCOMMAND} ${args}`, {
    cwd: sandboxPath,
    env: {...process.env, ESY__PREFIX: esyPrefixPath},
  });
}

async function buildOcamlPackage() {
  await mkdirOrIgnore(testPath);

  await mkdirOrIgnore(sandboxPath);
  await fs.writeFile(path.join(sandboxPath, 'package.json'), JSON.stringify({
    name: 'root-project',
    version: '1.0.0',
    dependencies: {
      ocaml: 'esy-ocaml/ocaml#6aacc05',
    },
    esy: {
      build: [],
      install: [],
    },
  }));

  await esy('install');
  await esy('build');

  const buildEnv = JSON.parse((await esy('build-env --json')).stdout);
  const PATH = (buildEnv.PATH || '').split(path.delimiter);

  let ocamloptPath = null;
  for (const p of PATH) {
    if (fs.exists(path.join(p, 'ocamlopt'))) {
      ocamloptPath = path.join(p, 'ocamlopt');
      break;
    }
  }

  if (ocamloptPath == null) {
    throw new Error('unable to initialize ocaml package for tests');
  }

  await mkdirOrIgnore(ocamlPackagePath);
  await fs.writeFile(path.join(ocamlPackagePath, 'package.json'), JSON.stringify({
    name: 'ocaml',
    version: '1.0.0',
    esy: {
      build: [
        "true"
      ],
      install: [
        "cp ocamlopt #{self.bin / 'ocamlopt'}",
        "chmod +x #{self.bin / 'ocamlopt'}"
      ]
    },
  }));

  await fs.copyFile(ocamloptPath, path.join(ocamlPackagePath, 'ocamlopt'));
}

module.exports = async function jestGlobalSetup(_globalConfig /* : any */) {
  if (!await fs.exists(ocamlPackagePath)) {
    await buildOcamlPackage();
  }
};

module.exports.ocamlPackagePath = ocamlPackagePath;
