const admin = require('firebase-admin');
admin.initializeApp();
exports.platformApi = require('./platform').platformApi;
exports.schoolCloudApi = require('./school-cloud').schoolCloudApi;
