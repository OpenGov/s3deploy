CREATE TABLE deployments
(
  git_revision  character(40) UNIQUE PRIMARY KEY NOT NULL, -- Must be SHA commit hash, should not put a branch or a tag
  git_branch character varying(255) DEFAULT NULL, -- Branch or tag
  git_repo_name character varying(255) DEFAULT NULL,
  git_url character varying(255) DEFAULT NULL,

  pull_request character(64) DEFAULT NULL,
  url_affix character(64) DEFAULT NULL,

  s3_bucket character varying(255) NOT NULL,
  s3_object_path text NOT NULL, -- in the form of <GIT_REP_NAME>/<BRANCH>/<YEAR>/<MONTH>/<GIT_SHA_COMMIT>.tar.gz
  s3_object_etag text NOT NULL, -- the AWS md5 hash of the tarball

  tarball_checksum character(64) UNIQUE DEFAULT NULL, -- The checksum should be a sha256
  created timestamp without time zone NOT NULL DEFAULT now()
);

CREATE INDEX index_deployments_on_created
  ON deployments
  USING btree
  (created);

-- Sample data
INSERT INTO deployments(git_revision, git_branch, git_repo_name, git_url, pull_request, url_prefix, s3_bucket, s3_object_path, s3_object_etag, tarball_checksum, created)
VALUES
       ('060f3ff438b4f82ef57d8ef1c5bc467feb8a8a74', 'master', 'DelphiusApp', 'git@github.com:OpenGov/DelphiusApp.git', '5781', 'delphius-app-5781', 'og-deployments', 'DelphiusApp/master/2014/03/060f3ff438b4f82ef57d8ef1c5bc467feb8a8a74.tar.gz', '4bdc0d6def42a22ed4e9d55228c61578', NUll, '2014-03-14 10:23:54'),
       ('08a673aa93b86dfb7d05e393d0a7aaec033b4223', 'master', 'DelphiusApp', 'git@github.com:OpenGov/DelphiusApp.git', '5901', 'delphius-app-5901', 'og-deployments', 'DelphiusApp/master/2014/03/08a673aa93b86dfb7d05e393d0a7aaec033b4223.tar.gz', '170e3523aa2af0450a7fe2b4b786ac07', NUll, '2014-03-20 19:12:09'),
       ('1737ab5652f6c9ca035da6e70b9eaa26aac816c2', 'master', 'DelphiusApp', 'git@github.com:blazzy/DelphiusApp.git', '6781', 'delphius-app-6781', 'og-deployments', 'DelphiusApp/master/2014/03/1737ab5652f6c9ca035da6e70b9eaa26aac816c2.tar.gz', '6bcf2c9142eb1b645c3e50a7be7ba625', NULL, '2014-03-07 17:34:44'),
       ('218340d5ed9f33ea019b07b8fec89d73304f43a0', 'master', 'DelphiusApp', 'git@github.com:blazzy/DelphiusApp.git', '7919', 'blazzy-dapp-v3', 'og-deployments', 'DelphiusApp/master/2014/02/218340d5ed9f33ea019b07b8fec89d73304f43a0.tar.gz', '6d1b2069ef8557651adbeb27842f2881', NULL, '2014-02-01 12:11:42'),
       ('3bd794304de43ca4eac48ddc97b7b5ed4bcb2d95', 'master', 'DelphiusApp', 'git@github.com:Chili-Man/DelphiusApp.git', '8912', 'delphius-app-8912', 'og-deployments', 'DelphiusApp/master/2014/03/3bd794304de43ca4eac48ddc97b7b5ed4bcb2d95.tar.gz', '5edfd095239df1de91daf1f927ecdad2-33', NULL, '2014-03-07 01:54:21');

INSERT INTO deployments(git_revision, git_branch, git_repo_name, s3_bucket, s3_object_path, s3_object_etag)
VALUES
       ('5d820e673129f14cb314596d79e680212c7fa4c2', 'master', 'DelphiusApp', 'og-deployments', 'DelphiusApp/master/2014/03/5d820e673129f14cb314596d79e680212c7fa4c2.tar.gz', 'f72eeb0275d4348d5bc6abb5a113ca87');

-- Select the newest record
SELECT * FROM deployments ORDER BY created DESC LIMIT 1;
