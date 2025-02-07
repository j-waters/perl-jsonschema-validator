#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use lib 't/lib';

use Helper 'test_dir';
use JSONSchema::Validator;
use JSONSchema::Validator::Util qw/get_resource decode_content/;

for my $validator_class (@{$JSONSchema::Validator::JSON_SCHEMA_VALIDATORS}) {
    my $specification = lc($validator_class->SPECIFICATION);
    my $glob_file_tests = test_dir("data/json_schema/${specification}/*.json");
    my @file_tests = glob($glob_file_tests);
    for my $file (@file_tests) {
        my $uri = URI::file->new($file)->as_string;
        my $tests = decode_content(get_resource({}, $uri), $uri);
        for my $test (@$tests) {
            my $test_topic = $test->{subject};
            my $validator = $validator_class->new(schema => $test->{schema});
            my $subtests = $test->{tests};
            for my $t (@$subtests) {
                my $test_name = $specification . ': ' . $test_topic . ': ' . $t->{description};
                my ($result, $errors) = $validator->validate_schema($t->{data});
                if ($t->{valid}) {
                    is $result, 1, $test_name;
                    is @$errors, 0, $test_name . '; errors is empty';
                } else {
                    is $result, 0, $test_name;
                    ok @$errors > 0, $test_name . '; errors is not empty';
                    for my $e (@$errors) {
                        is ref $e, 'JSONSchema::Validator::Error', $test_name . '; check error type';
                    }
                }
            }
        }
    }
}

done_testing;
