package JSONSchema::Validator;

# ABSTRACT: Validator for JSON Schema

use strict;
use warnings;
use URI::file;
use Carp 'croak';

use JSONSchema::Validator::Util qw(get_resource decode_content read_file);

our $VERSION = '0.001';

my $SPECIFICATIONS = {
    'https://spec.openapis.org/oas/3.0/schema/2019-04-02' => 'OAS30',
    'http://json-schema.org/draft-04/schema#' => 'Draft4'
};

my $KNOWN_SPECIFICATIONS = ['OAS30', 'Draft4'];

sub new {
    my ($class, %params) = @_;

    my $resource = delete $params{resource};
    my $validate_schema = delete($params{validate_schema}) // 1;
    my $schema = delete $params{schema};
    my $base_uri = delete $params{base_uri};
    my $specification = delete $params{specification};

    $schema = resource_schema($resource, \%params) if !$schema && $resource;
    croak 'resource or schema must be specified' unless $schema;

    $specification = schema_specification($schema) unless $specification;
    ($specification) = grep { lc eq lc($specification // '') } @$KNOWN_SPECIFICATIONS;
    croak 'unknown specification' unless $specification;

    if ($validate_schema) {
        my ($result, $errors) = $class->validate_resource_schema($schema, $specification);
        croak "invalid schema:\n" . join "\n", @$errors unless $result;
    }

    my $validator_class = "JSONSchema::Validator::${specification}";
    croak "Unknown specification param $specification" unless eval { require $validator_class; 1 };

    $base_uri //= $resource || $schema->{'$id'} || $schema->{id};

    return $validator_class->new(schema => $schema, base_uri => $base_uri, %params);
}

sub validate_paths {
    my ($class, $globs) = @_;
    my $results = {};
    for my $glob (@$globs) {
        my @resources = glob $glob;
        for my $resource (@resources) {
            my $uri = URI::file->new($resource)->as_string;
            my ($result, $errors) = $class->validate_resource($uri);
            $results->{$resource} = [$result, $errors];
        }
    }
    return $results;
}

sub validate_resource {
    my ($class, $resource, %params) = @_;
    my $schema_to_validate = resource_schema($resource, \%params);

    my $specification = schema_specification($schema_to_validate);
    ($specification) = grep { lc eq lc($specification // '') } @$KNOWN_SPECIFICATIONS;
    croak "unknown specification of resource $resource" unless $specification;

    return $class->validate_resource_schema($schema_to_validate, $specification);
}

sub validate_resource_schema {
    my ($class, $schema_to_validate, $schema_specification) = @_;

    my $schema = read_specification($schema_specification);
    my $meta_schema = $schema->{'$schema'};

    my $validator_name = $SPECIFICATIONS->{$meta_schema};
    my $validator_class = "JSONSchema::Validator::${validator_name}";
    eval { require $validator_class; 1 };

    my $validator = $validator_class->new(schema => $schema);
    my ($result, $errors) = $validator->validate_schema($schema_to_validate);
    return ($result, $errors);
}

sub read_specification {
    my $filename = shift;
    my $curret_filepath = __FILE__;
    my $schema_filepath = ($curret_filepath =~ s/.pm//r) . '/schemas/' . lc($filename) . '.json';
    my ($content, $mime_type) = read_file($schema_filepath);
    return decode_content($content, $mime_type, $schema_filepath);
}

sub resource_schema {
    my ($resource, $params) = @_;
    my ($response, $mime_type) = get_resource($params->{scheme_handlers}, $params->{user_agent_get}, $resource);
    my $schema = decode_content($response, $mime_type, $resource);
    return $schema;
}

sub schema_specification {
    my $schema = shift;

    my $meta_schema = $schema->{'$schema'};
    my $specification = $meta_schema ? $SPECIFICATIONS->{$meta_schema} : undef;

    if (!$specification && $schema->{openapi}) {
        my @vers = split /\./, $schema->{openapi};
        $specification = 'OAS' . $vers[0] . $vers[1];
    }

    return $specification;
}

1;
