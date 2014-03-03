CREATE TABLE deployments
(
  git_revision  character(40) UNIQUE PRIMARY KEY NOT NULL,
  git_branch character varying(255),
  git_repo_name character varying(255),
  
  s3_bucket character varying(255) NOT NULL,
  s3_object_path text NOT NULL,
  s3_object_etag text NOT NULL,

  tarball_checksum character(64) UNIQUE NOT NULL,
  created timestamp without time zone NOT NULL DEFAULT now()
);

CREATE INDEX index_deployments_on_created
  ON deployments
  USING btree
  (created);
