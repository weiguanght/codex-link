; Adapted for Runestone; source and license notices: LANGUAGE_SOURCES.md and Tests/Additional/Dockerfile.json.
[
	"FROM"
	"AS"
	"RUN"
	"CMD"
	"LABEL"
	"EXPOSE"
	"ENV"
	"ADD"
	"COPY"
	"ENTRYPOINT"
	"VOLUME"
	"USER"
	"WORKDIR"
	"ARG"
	"ONBUILD"
	"STOPSIGNAL"
	"HEALTHCHECK"
	"SHELL"
	"MAINTAINER"
	"CROSS_BUILD"
] @keyword

[
	":"
	"@"
] @operator

(comment) @comment


(image_spec
	(image_tag
		":" @punctuation.delimiter)
	(image_digest
		"@" @punctuation.delimiter))

[
  (double_quoted_string)
  (single_quoted_string)
  (json_string)
] @string

(expansion
  [
	"$"
	"{"
	"}"
  ] @punctuation.delimiter
) @none

((variable) @constant
 (#match? @constant "^[A-Z][A-Z_0-9]*$"))


