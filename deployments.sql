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

INSERT INTO deployments(git_revision, git_branch, git_repo_name, s3_bucket, s3_object_path, tarball_checksum)
  VALUES 
    ('0f1c8e03fbc1f87d131fb36c290cc321136f15a6',
     'master',				       
    )
