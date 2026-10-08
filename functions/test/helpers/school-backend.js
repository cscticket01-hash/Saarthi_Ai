'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
function iterator(items) { let i = 0; return {hasNext: () => i < items.length, next: () => items[i++]}; }
function drive() {
  const folders = new Map(), files = new Map();
  function folder(name, parent) {
    const f = {id: crypto.randomUUID(), name, parent, description: '',
      getId() {return this.id;}, getDescription() {return this.description;},
      setDescription(v) {this.description = v; return this;}, getName() {return this.name;},
      getParents() {return iterator(this.parent ? [this.parent] : []);},
      getFilesByName(n) {return iterator([...files.values()].filter(f => f.parent === this && f.name === n));},
      getFoldersByName(n) {return iterator([...folders.values()].filter(f => f.parent === this && f.name === n));},
      createFolder(n) {return folder(n, this);}, moveTo(p) {this.parent = p; return this;}};
    folders.set(f.id, f); return f;
  }
  function sheetFile(name, parent) {
    const sheet = {rows: [], getLastRow() {return this.rows.length;},
      getLastColumn() {return Math.max(0, ...this.rows.map(r => r.length));},
      getRange(r, c, count, width) {
        return {getValues: () => Array.from({length: count}, (_, i) =>
          Array.from({length: width}, (_, j) => this.rows[r - 1 + i]?.[c - 1 + j] ?? '')),
          setValues: values => {values.forEach((row, i) => {
            this.rows[r - 1 + i] ||= [];
            row.forEach((v, j) => this.rows[r - 1 + i][c - 1 + j] = v);
          });}};
      }};
    const file = {id: crypto.randomUUID(), name, parent, sheet,
      getId() {return this.id;}, getName() {return this.name;}, getMimeType() {return 'sheets';},
      getParents() {return iterator(this.parent ? [this.parent] : []);}, moveTo(p) {this.parent = p; return this;},
      getBlob() {return {getContentType: () => 'image/png', getBytes: () => Buffer.from('own-photo')};}};
    files.set(file.id, file); return file;
  }
  const globalRoot = folder('My Drive');
  return {folders, files, folder, sheetFile, globalRoot,
    DriveApp: {createFolder: n => folder(n, globalRoot), getFolderById: id => folders.get(id),
      getFileById: id => files.get(id), getRootFolder: () => globalRoot,
      getFilesByName() {throw Error('Unsafe global sheet search');},
      getFoldersByName() {throw Error('Unsafe global folder search');}},
    SpreadsheetApp: {create: n => {const f = sheetFile(n, globalRoot); return {getId: () => f.id, getSheets: () => [f.sheet]};},
      openById: id => ({getSheets: () => [files.get(id).sheet]})}};
}
function school(project = 'school-one', world = drive()) {
  const properties = new Map(), cache = new Map(), acceptedTokens = new Map(), requests = [], database = new Map();
  const props = {getProperty: k => properties.get(k) || null,
    setProperty(k, v) {properties.set(k, String(v)); return this;}};
  const context = vm.createContext({Date, JSON, Math, Number, String, Object, Array, Error, console,
    PropertiesService: {getScriptProperties: () => props},
    CacheService: {getScriptCache: () => ({get: k => cache.get(k), put: (k, v) => cache.set(k, v)})},
    ContentService: {MimeType: {JSON: 'json'}, createTextOutput: text => ({getContent: () => text, setMimeType() {return this;}})},
    Utilities: {DigestAlgorithm: {SHA_256: 'sha256'}, computeDigest: (_, s) => [...crypto.createHash('sha256').update(s).digest()],
      getUuid: () => crypto.randomUUID(), base64DecodeWebSafe: s => [...Buffer.from(s, 'base64url')],
      newBlob: bytes => ({getDataAsString: () => Buffer.from(bytes).toString()}),
      base64Encode: bytes => Buffer.from(bytes).toString('base64'),
      formatDate: d => d.toISOString().slice(0, 10)},
    ScriptApp: {getOAuthToken: () => 'owner-oauth'}, LockService: {getScriptLock: () => ({waitLock() {}, releaseLock() {}})},
    MimeType: {GOOGLE_SHEETS: 'sheets'}, DriveApp: world.DriveApp, SpreadsheetApp: world.SpreadsheetApp,
    UrlFetchApp: {fetch(url, options) {
      requests.push({url, options});
      if (url.includes('accounts:lookup')) {
        const user = acceptedTokens.get(JSON.parse(options.payload).idToken);
        return {getResponseCode: () => user ? 200 : 400, getContentText: () => JSON.stringify(user ? {users: [user]} : {error: 'INVALID_ID_TOKEN'})};
      }
      return {getResponseCode: () => 200, getContentText: () => '{}'};
    }}});
  for (const name of ['SaarthiSchool.gs', 'SaarthiStorage.gs', 'SaarthiMobile.gs', 'SaarthiPlatform.gs']) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, '../../../school-backend', name), 'utf8'), context, {filename: name});
  }
  context.VS_setupSchool(project, 'AIza' + 'a'.repeat(33));
  function token(changes = {}) {
    const claims = {aud: project, iss: 'https://securetoken.google.com/' + project,
      sub: 'school-owner', admin: true, auth_time: Math.floor(Date.now() / 1000) - 10,
      exp: Math.floor(Date.now() / 1000) + 3600, ...changes};
    const t = Buffer.from('{}').toString('base64url') + '.' + Buffer.from(JSON.stringify(claims)).toString('base64url') + '.registered-signature';
    acceptedTokens.set(t, {localId: claims.sub, validSince: 1}); return t;
  }
  const proof = () => ({schoolProjectId: project, schoolAdminIdToken: token()});
  const post = body => JSON.parse(context.doPost({postData: {contents: JSON.stringify(body)}}).getContent());
  return {context, world, properties, database, requests, acceptedTokens, token, proof, post,
    prepare: () => context.VS_prepareSchoolStorage({startEmpty: true})};
}
module.exports = {drive, school};
