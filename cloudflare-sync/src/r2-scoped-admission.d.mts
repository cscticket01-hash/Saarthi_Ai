export declare function r2StagingForSchool(
  env: {
    R2_STAGING_ENABLED?: string;
    R2_STAGING_SCHOOLS?: string;
    R2_STAGING_ALL_SCHOOLS_ENABLED?: string;
    LIVE_SYNC_TEST_SCHOOL_ID?: string;
  },
  school: string,
): boolean;
