'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const source=fs.readFileSync('../school-backend/managed/SaarthiManagedAdapter.gs','utf8');
function avatar(root) {
  const context=vm.createContext({});
  vm.runInContext(source,context);
  return JSON.parse(JSON.stringify(context.VS_managedOwnerProfilePhoto(root)));
}
test('signed school script resolves existing Drive owner photo without Google OAuth prompt',()=>{
  const original='https://lh3.googleusercontent.com/a/photo.gif';
  const result=avatar({getOwner:()=>({
    getEmail:()=> 'ADMIN@GMAIL.COM',
    getPhotoUrl:()=> original
  })});
  assert.deepEqual(result,{profilePhotoEmail:'admin@gmail.com',profilePhotoUrl:original});
});
test('missing owner or invalid photo cannot break school health',()=>{
  assert.deepEqual(avatar({}),{});
  assert.deepEqual(avatar({getOwner:()=>null}),{});
  assert.deepEqual(avatar({getOwner:()=>{throw Error('unavailable')}}),{});
  assert.deepEqual(avatar({getOwner:()=>({
    getEmail:()=> 'admin@gmail.com',
    getPhotoUrl:()=> 'https://googleusercontent.com.attacker.invalid/evil.gif'
  })}),{});
  assert.deepEqual(avatar({getOwner:()=>({
    getEmail:()=> 'admin@gmail.com',
    getPhotoUrl:()=> 'http://lh3.googleusercontent.com/evil.gif'
  })}),{});
});
