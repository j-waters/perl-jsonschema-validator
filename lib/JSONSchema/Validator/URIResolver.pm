package JSONSchema::Validator::URIResolver;

use strict;
use warnings;
use Carp 'croak';

use Scalar::Util 'weaken';

use URI;
use URI::Escape;
use Encode;

use JSONSchema::Validator::JSONPointer 'json_pointer';
use JSONSchema::Validator::Util qw(get_resource decode_content);

# what keys contain the schema? Required to find an $id in a schema
my $SEARCH_ID = {
    value => {
        additionalItems => 1,
        items => 1,
        additionalProperties => 1,
        not => 1
    },
    kv_value => {
        properties => 1,
        patternProperties => 1,
        dependencies => 1,
        definitions => 1
    },
    arr_value => {
        items => 1,
        allOf => 1,
        anyOf => 1,
        oneOf => 1
    }
};

sub new {
    my ($class, %params) = @_;

    my $validator   = $params{validator} || croak 'URIResolver: validator must be specified';
    my $schema      = $params{schema} || croak 'URIResolver: schema must be specified';
    my $base_uri    = $params{base_uri} // '';

    my $user_agent_get      = $params{user_agent_get};
    my $scheme_handlers     = $params{scheme_handlers} // {};

    weaken($validator);

    my $self = {
        validator => $validator,
        cache => {
            $base_uri => $schema
        },
        user_agent_get => $user_agent_get,
        scheme_handlers => $scheme_handlers
    };

    bless $self, $class;

    $self->cache_id(URI->new($base_uri), $schema) if $validator->using_id_with_ref;

    return $self;
}

sub validator { shift->{validator} }
sub user_agent_get { shift->{user_agent_get} }
sub scheme_handlers { shift->{scheme_handlers} }
sub cache { shift->{cache} }

# self - URIResolver
# origin_uri - URI
# return (scope|string, schema)
sub resolve {
    my ($self, $origin_uri) = @_;

    return ($origin_uri->as_string, $self->cache->{$origin_uri->as_string}) if exists $self->cache->{$origin_uri->as_string};

    my $uri = $origin_uri->clone;
    $uri->fragment(undef);

    my $schema = $self->cache_resolve($uri);
    return $self->fragment_resolve($origin_uri, $schema);
}

# self - URIResolver
# uri - URI
# return schema
sub cache_resolve {
    my ($self, $uri) = @_;

    my $scheme = $uri->scheme;

    return $self->cache->{$uri->as_string} if exists $self->cache->{$uri->as_string};

    my ($response, $mime_type) = get_resource($self->scheme_handlers, $self->user_agent_get, $uri->as_string);
    my $schema = decode_content($response, $mime_type, $uri->as_string);

    $self->cache->{$uri->as_string} = $schema;

    $self->cache_id($uri, $schema) if $self->validator->using_id_with_ref;

    return $schema;
}

# self - URIResolver
# uri - URI
# schema - HASH/ARRAY
# return (scope|string, schema)
sub fragment_resolve {
    my ($self, $uri, $schema) = @_;
    return ($uri->as_string, $self->cache->{$uri->as_string}) if exists $self->cache->{$uri->as_string};

    my $enc = Encode::find_encoding("UTF-8");
    my $fragment = $enc->decode(uri_unescape($uri->fragment), 1);

    my $pointer = json_pointer->new(
        scope => $uri->as_string,
        value => $schema,
        validator => $self->validator
    );

    # try to use fragment as json pointer
    $pointer = $pointer->get($fragment);
    my $subschema = $pointer->value;
    my $current_scope = $pointer->scope;

    $self->cache->{$uri->as_string} = $subschema;

    return ($current_scope, $subschema);
}

# self - URIResolver
# uri - URI
# schema - HASH/ARRAY
sub cache_id {
    my ($self, $uri, $schema) = @_;

    # try to find id/$id and cache it to properly handle links in $ref
    # https://json-schema.org/understanding-json-schema/structuring.html#using-id-with-ref

    my $scopes = [$uri];
    $self->cache_id_dfs($schema, $scopes);
}

# self - URIResolver
# schema - HASH/ARRAY
# scopes - [URI, ...]
sub cache_id_dfs {
    my ($self, $schema, $scopes) = @_;
    return unless ref $schema eq 'HASH';

    if (exists $schema->{$self->validator->ID} && !ref $schema->{$self->validator->ID}) {
        my $id = URI->new($schema->{$self->validator->ID});
        my $scope = $scopes->[-1];

        $id = ($scope && $scope->as_string) ? $id->abs($scope) : $id;

        $self->cache->{$id->as_string} = $schema;
        push @$scopes, $id;
    }

    for my $k (keys %$schema) {
        if ($SEARCH_ID->{value}{$k} && ref $schema->{$k} eq 'HASH') {
            $self->cache_id_dfs($schema->{$k}, $scopes);
        }

        if ($SEARCH_ID->{arr_value}{$k} && ref $schema->{$k} eq 'ARRAY') {
            for my $value (@{$schema->{$k}}) {
                next unless ref $value eq 'HASH';
                $self->cache_id_dfs($value, $scopes);
            }
        }

        if ($SEARCH_ID->{kv_value}{$k} && ref $schema->{$k} eq 'HASH') {
            for my $kv_key (keys %{$schema->{$k}}) {
                my $value = $schema->{$k}{$kv_key};
                next unless ref $value eq 'HASH';
                $self->cache_id_dfs($value, $scopes);
            }
        }
    }

    if (exists $schema->{$self->validator->ID} && !ref $schema->{$self->validator->ID}) {
        pop @$scopes;
    }
}

1;