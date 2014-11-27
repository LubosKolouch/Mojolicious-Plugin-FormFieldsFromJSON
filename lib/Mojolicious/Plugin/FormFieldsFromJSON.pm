package Mojolicious::Plugin::FormFieldsFromJSON;
use Mojo::Base 'Mojolicious::Plugin';

# ABSTRACT: create form fields based on a definition in a JSON file

our $VERSION = '0.01';

use Carp;
use File::Spec;

use Mojo::Asset::File;
use Mojo::Collection;
use Mojo::JSON qw(decode_json);

our %request;

sub register {
    my ($self, $app, $config) = @_;
  
    my %configs;
    my $dir = $config->{dir} || '.';
  
    my %valid_types = (
        text     => 1,
        checkbox => 1,
        select   => 1,
        radio    => 1,
    );

    $app->helper(
        'validate_form_fields' => sub {
            my ($c, $file) = @_;
  
            return '' if !$file;
  
            if ( !$configs{$file} ) {
                $c->form_fields( $file, only_load => 1 );
            }
  
            return '' if !$configs{$file};
  
            my $config = $configs{$file};

            my $validation = $c->validation;
            $validation->input( $c->tx->req->params->to_hash );

            my %errors;
  
            FIELD:
            for my $field ( @{ $config } ) {
                if ( 'HASH' ne ref $field ) {
                    $app->log->error( 'Field definition must be a HASH - skipping field' );
                    next FIELD;
                }

                if ( !$field->{validation} ) {
                    next FIELD;
                }

                if ( 'HASH' ne ref $field->{validation} ) {
                    $app->log->warn( 'Validation settings must be a HASH - skipping field' );
                    next FIELD;
                }

                my $name = $field->{name} // $field->{label} // '';

                if ( $field->{validation}->{required} ) {
                    $validation->required( $name );
                }
                else {
                    $validation->optional( $name );
                }

                RULE:
                for my $rule ( keys %{ $field->{validation} } ) {
                    my @params = ( $field->{validation}->{$rule} );
                    my $method = $rule;

                    if ( ref $field->{validation}->{$rule} ) {
                        @params = @{ $field->{validation}->{$rule} };
                    }

                    if ( $method eq 'required' ) {
                        $validation->required( $name );
                        next RULE;
                    }

                    eval{
                        $validation->check( $method, @params );
                    } or do {
                        $app->log->error( "Validating $name with rule $method failed: $@" );
                    };

                    if ( !$validation->is_valid( $name ) ) {
                        $errors{$name} = 1;
                        last RULE;
                    }
                }

                if ( !$validation->is_valid( $name ) ) {
                    $errors{$name} = 1;
                }
            }

            return %errors;
        }
    );
  
    $app->helper(
        'form_fields' => sub {
            my ($c, $file, %params) = @_;
  
            return '' if !$file;
  
            if ( !$configs{$file} ) {
                my $path = File::Spec->catfile( $dir, $file . '.json' );
                return '' if !-r $path;
  
                eval {
                    my $content = Mojo::Asset::File->new( path => $path )->slurp;
                    $configs{$file} = decode_json $content;
                } or do {
                    $app->log->error( "FORMFIELDS $file: $@" );
                    return '';
                };
  
                if ( 'ARRAY' ne ref $configs{$file} ) {
                    $app->log->error( 'Definition JSON must be an ARRAY' );
                    return '';
                }
            }
 
            return if $params{only_load}; 
            return '' if !$configs{$file};
  
            my $config = $configs{$file};

            my @fields;
  
            FIELD:
            for my $field ( @{ $config } ) {
                if ( 'HASH' ne ref $field ) {
                    $app->log->error( 'Field definition must be an HASH - skipping field' );
                    next FIELD;
                }
  
                my $type = $field->{type};
  
                if ( !$valid_types{$type} ) {
                    $app->log->warn( "Invalid field type $type - falling back to 'text'" );
                    $type = 'text';
                }

                local %request = %{ $c->tx->req->params->to_hash };
  
                my $sub   = $self->can( '_' . $type );
                my $field = $self->$sub( $c, $field, %params );
                push @fields, $field;
            }

            return @fields;
        }
    );
}

sub _text {
    my ($self, $c, $field) = @_;

    my $name  = $field->{name} // $field->{label} // '';
    my $value = $c->stash( $name ) // $request{$name} // $field->{data} // '';
    my $id    = $field->{id} // $name;
    my %attrs = %{ $field->{attributes} || {} };

    return $c->text_field( $name, $value, id => $id, %attrs );
}

sub _select {
    my ($self, $c, $field, %params) = @_;

    my $name   = $field->{name} // $field->{label} // '';

    my $field_params = $params{$name} || {},

    my %select_params = (
       disabled => $self->_get_highlighted_values( $field, 'disabled' ),
       selected => $self->_get_highlighted_values( $field, 'selected' ),
    );

    my $stash_values = $c->every_param( $name );
    my $reset;
    if ( @{ $stash_values || [] } ) {
        $select_params{selected} = $self->_get_highlighted_values(
            +{ selected => $stash_values },
            'selected',
        );
        $c->param( $name, '' );
        $reset = 1;
    }

    for my $key ( qw/disabled selected/ ) {
        my $hashref = $self->_get_highlighted_values( $field_params, $key );
        if ( keys %{ $hashref } ) {
            $select_params{$key} = $hashref;
        }
    }

    my @values = $self->_get_select_values( $c, $field, %select_params );
    my $id     = $field->{id} // $name;
    my %attrs  = %{ $field->{attributes} || {} };

    if ( $field->{multiple} ) {
        $attrs{multiple} = 'multiple';
        $attrs{size}     = $field->{size} || 5;
    }

    my $select_field = $c->select_field( $name, [ @values ], id => $id, %attrs );

    # reset parameters
    if ( $reset ) {
        my $single = scalar @{ $stash_values };
        my $param  = $single == 1 ? $stash_values->[0] : $stash_values;
        $c->param( $name, $param );
    }

    return $select_field;
}

sub _get_highlighted_values {
    my ($self, $field, $key) = @_;

    return +{} if !$field->{$key};

    my %highlighted;

    if ( !ref $field->{$key} ) {
        my $value = $field->{$key};
        $highlighted{$value} = 1;
    }
    elsif ( 'ARRAY' eq ref $field->{$key} ) {
        for my $value ( @{ $field->{$key} } ) {
            $highlighted{$value} = 1;
        }
    }

    return \%highlighted;
}

sub _get_select_values {
    my ($self, $c, $field, %params) = @_;

    my $data = $params{data} || $field->{data} || [];

    my @values;
    if ( 'ARRAY' eq ref $data ) {
        @values = $self->_transform_array_values( $data, %params );
    }

    return @values;
}

sub _transform_array_values {
    my ($self, $data, %params) = @_;

    my @values;
    my $numeric = 1;

    for my $value ( @{ $data } ) {
        if ( $numeric && $value =~ m{[^0-9]} ) {
            $numeric = 0;
        }

        my %opts;

        $opts{disabled} = 'disabled' if $params{disabled}->{$value};
        $opts{selected} = 'selected' if $params{selected}->{$value};

        push @values, [ $value => $value, %opts ];
    }

    @values = $numeric ?
        sort{ $a->[0] <=> $b->[0] }@values :
        sort{ $a->[0] cmp $b->[0] }@values;

    return @values;
}

sub _radio {
}

sub _checkbox {
}

1;

__END__

=encoding utf8

=head1 SYNOPSIS

  # Mojolicious
  $self->plugin('FormFieldsFromJSON');

  # Mojolicious::Lite
  plugin 'FormFieldsFromJSON';

=head1 DESCRIPTION

L<Mojolicious::Plugin::FormFieldsFromJSON> is a L<Mojolicious> plugin.

=head1 HELPER

=head2 form_fields

  $controller->form_fields( 'formname' );

=head1 FIELD DEFINITIONS

This plugin supports several form fields:

=over 4

=item * text

=item * checkbox

=item * radio

=item * select

=back

Those fields have the following definition items in common:

=over 4

=item * label

=item * type

=item * data

=item * data_function

=item * attributes

Attributes of the field like "class"

=back

=head1 EXAMPLES

The following sections should give you an idea what's possible with this plugin

=head2 text

=head3 A simple text field

=head3 Set CSS classes

=head2 select

=head3 Simple: Value = Label

When you have a list of values for a select field, you can define
an array reference:

  [
    {
      "type" : "select",
      "name" : "language",
      "data" : [
        "de",
        "en"
      ]
    }
  ]

This creates the following select field:

  <select id="language" name="language">
      <option value="de">de</option>
      <option value="en">en</option>
  </select>

=head3 Preselect a value

You can define

  [
    {
      "type" : "select",
      "name" : "language",
      "data" : [
        "de",
        "en"
      ],
      "selected" : "en"
    }
  ]

This creates the following select field:

  <select id="language" name="language">
      <option value="de">de</option>
      <option value="en" selected="selected">en</option>
  </select>

If a key named as the select exists in the stash, those values are preselected
(this overrides the value defined in the .json):

  $c->stash( language => 'en' );

and

  [
    {
      "type" : "select",
      "name" : "language",
      "data" : [
        "de",
        "en"
      ]
    }
  ]

This creates the following select field:

  <select id="language" name="language">
      <option value="de">de</option>
      <option value="en" selected="selected">en</option>
  </select>

=head3 Multiselect

  [
    {
      "type" : "select",
      "name" : "languages",
      "data" : [
        "de",
        "en",
        "cn",
        "jp"
      ],
      "multiple" : 1,
      "size" : 3
    }
  ]

This creates the following select field:

  <select id="languages" name="languages" multiple="multiple" size="3">
      <option value="cn">cn</option>
      <option value="de">de</option>
      <option value="en">en</option>
      <option value="jp">jp</option>
  </select>

=head3 Preselect multiple values

  [
    {
      "type" : "select",
      "name" : "languages",
      "data" : [
        "de",
        "en",
        "cn",
        "jp"
      ],
      "multiple" : 1,
      "selected" : [ "en", "de" ]
    }
  ]

This creates the following select field:

  <select id="language" name="language">
      <option value="cn">cn</option>
      <option value="de" selected="selected">de</option>
      <option value="en" selected="selected">en</option>
      <option value="jp">jp</option>
  </select>

=head3 Values != Label

  [
    {
      "type" : "select",
      "name" : "language",
      "data" : {
        "de" : "German",
        "en" : "English"
      }
    }
  ]

This creates the following select field:

  <select id="language" name="language">
      <option value="en">English</option>
      <option value="de">German</option>
  </select>

=head3 Option groups

  [
    {
      "type" : "select",
      "name" : "language",
      "data" : {
        "EU" : {
          "de" : "German",
          "en" : "English"
        },
        "Asia" : {
          "cn" : "Chinese",
          "jp" : "Japanese"
        }
      }
    }
  ]

This creates the following select field:

  <select id="language" name="language">
      <option value="en">English</option>
      <option value="de">German</option>
  </select>

=head3 Disable values

  [
    {
      "type" : "select",
      "name" : "languages",
      "data" : [
        "de",
        "en",
        "cn",
        "jp"
      ],
      "multiple" : 1,
      "disabled" : [ "en", "de" ]
    }
  ]

This creates the following select field:

  <select id="language" name="language">
      <option value="cn">cn</option>
      <option value="de" disabled="disabled">de</option>
      <option value="en" disabled="disabled">en</option>
      <option value="jp">jp</option>
  </select>

=head2 radio

=head2 checkbox

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
