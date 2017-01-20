package VMware::vCloudDirector::API;

# ABSTRACT: Module to do stuff!

use strict;
use warnings;

# VERSION
# AUTHORITY

use Moose;
use Method::Signatures;
use MIME::Base64;
use MooseX::Types::Path::Tiny qw/Path/;
use Mozilla::CA;
use Path::Tiny;
use Ref::Util qw(is_plain_hashref);
use Smart::Comments;
use Syntax::Keyword::Try;
use VMware::vCloudDirector::Error;
use VMware::vCloudDirector::Object;
use VMware::vCloudDirector::UA;
use XML::Fast qw();

# ------------------------------------------------------------------------
has hostname   => ( is => 'ro', isa => 'Str',  required => 1 );
has username   => ( is => 'ro', isa => 'Str',  required => 1 );
has password   => ( is => 'ro', isa => 'Str',  required => 1 );
has orgname    => ( is => 'ro', isa => 'Str',  required => 1, default => 'System' );
has ssl_verify => ( is => 'ro', isa => 'Bool', default  => 1 );
has debug   => ( is => 'rw', isa => 'Bool', default => 0 );      # Defaults to no debug info
has timeout => ( is => 'rw', isa => 'Int',  default => 120 );    # Defaults to 120 seconds

has default_accept_header => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    builder => '_build_default_accept_header'
);

has _base_url => (
    is      => 'ro',
    isa     => 'URI',
    lazy    => 1,
    builder => '_build_base_url',
    writer  => '_set_base_url'
);

has ssl_ca_file => (
    is      => 'ro',
    isa     => Path,
    coerce  => 1,
    lazy    => 1,
    builder => '_build_ssl_ca_file'
);

method _build_ssl_ca_file () { return path( Mozilla::CA::SSL_ca_file() ); }
method _build_base_url () { return URI->new( sprintf( 'https://%s/', $self->hostname ) ); }
method _build_default_accept_header () { return ( 'application/*+xml;version=' . $self->api_version ); }

# ------------------------------------------------------------------------
has _ua => (
    is      => 'ro',
    isa     => 'VMware::vCloudDirector::UA',
    lazy    => 1,
    clearer => '_clear_ua',
    builder => '_build_ua'
);

method _build_ua () {
    return VMware::vCloudDirector::UA->new(
        ssl_verify  => $self->ssl_verify,
        ssl_ca_file => $self->ssl_ca_file,
        timeout     => $self->timeout,
    );
}

# ------------------------------------------------------------------------
method _decode_xml_response ($response) {
    try {
        return XML::Fast::xml2hash( $response->content );
    }
    catch {
        VMware::vCloudDirector::Error->throw(
            {   message  => "XML decode failed - " . join( ' ', $@ ),
                response => $response
            }
        );
    }
}

# ------------------------------------------------------------------------
method _encode_xml_content ($hash) {
    return XML::Hash::XS::hash2xml( $hash, method => 'LX' );
}

# ------------------------------------------------------------------------
method _request ($method, $url, $content?, $headers?) {
    my $uri = URI->new_abs( $url, $self->_base_url );
    ### Method:  $method
    ### URI:     $uri
    my $request = HTTP::Request->new( $method => $uri );

    # build headers
    if ( defined $content && length($content) ) {
        $request->content($content);
        $request->header( 'Content-Length', length($content) );
    }
    else {
        $request->header( 'Content-Length', 0 );
    }

    # add any supplied headers
    my $seen_accept;
    if ( defined($headers) ) {
        foreach my $h_name ( keys %{$headers} ) {
            $request->header( $h_name, $headers->{$h_name} );
            $seen_accept = 1 if ( lc($h_name) eq 'accept' );
        }
    }

    # set accept header
    $request->header( 'Accept', $self->default_accept_header ) unless ($seen_accept);

    # set auth header
    $request->header( 'x-vcloud-authorization', $self->authorization_token )
        if ( $self->has_authorization_token );

    # do request
    my $response;
    try { $response = $self->_ua->request($request); }
    catch {
        VMware::vCloudDirector::Error->throw(
            {   message => "$method request bombed",
                uri     => $uri,
                request => $request,
            }
        );
    }

    # Throw if this went wrong
    if ( $response->is_error ) {
        ### Response: $response
        VMware::vCloudDirector::Error->throw(
            {   message  => "$method request failed",
                uri      => $uri,
                request  => $request,
                response => $response
            }
        );
    }

    return $response;
}

# ------------------------------------------------------------------------

=head1 API SHORTHAND METHODS

=head2 api_version

* Relative URL: /api/versions

The C<api_version> holds the version number of the highest discovered non-
deprecated API, it is initialised by connecting to the C</api/versions>
endpoint, and is called implicitly during the login setup.  Once filled the
values are cached.

=cut

has api_version => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    clearer => '_clear_api_version',
    builder => '_build_api_version'
);
has _url_login => (
    is      => 'rw',
    isa     => 'URI',
    lazy    => 1,
    clearer => '_clear_url_login',
    builder => '_build_url_login'
);
has _raw_version => (
    is      => 'rw',
    isa     => 'HashRef',
    lazy    => 1,
    clearer => '_clear_raw_version',
    builder => '_build_raw_version'
);
has _raw_version_full => (
    is      => 'rw',
    isa     => 'HashRef',
    lazy    => 1,
    clearer => '_clear_raw_version_full',
    builder => '_build_raw_version_full'
);

method _build_api_version () { return $self->_raw_version->{Version}; }
method _build_url_login () { return URI->new( $self->_raw_version->{LoginUrl} ); }

method _build_raw_version () {
    my $hash    = $self->_raw_version_full;
    my $version = 0;
    my $version_block;
    for my $verblock ( @{ $hash->{SupportedVersions}{VersionInfo} } ) {
        next unless ( $verblock->{-deprecated} eq 'false' );
        if ( $verblock->{Version} > $version ) {
            $version_block = $verblock;
            $version       = $verblock->{Version};
        }
    }

    ### vCloud API version seen: $version
    ### vCloud API version block: $version_block
    die "No valid version block seen" unless ($version_block);

    return $version_block;
}

method _build_raw_version_full () {
    my $response = $self->_request( 'GET', '/api/versions', undef, { Accept => 'text/xml' } );
    return $self->_decode_xml_response($response);
}

# ------------------------ ------------------------------------------------
has authorization_token => (
    is        => 'ro',
    isa       => 'Str',
    writer    => '_set_authorization_token',
    clearer   => 'clear_authorization_token',
    predicate => 'has_authorization_token'
);

method login () {
    my $login_id = join( '@', $self->username, $self->orgname );
    my $encoded_auth = 'Basic ' . MIME::Base64::encode( join( ':', $login_id, $self->password ) );
    ### vCloud attempting login as: $login_id
    my $response =
        $self->_request( 'POST', $self->_url_login, undef, { Authorization => $encoded_auth } );

    # if we got here then it succeeded, since we throw on failure
    my $token = $response->header('x-vcloud-authorization');
    $self->_set_authorization_token($token);
    ### vCloud authentication token: $token

    # we also reset the base url to match the login URL
    ## $self->_set_base_url( $self->_url_login->clone->path('') );

    return VMware::vCloudDirector::Object->new(
        {   hash => $self->_decode_xml_response($response),
            api  => $self
        }
    );
}

# ------------------------------------------------------------------------
method GET ($url) {
    my $response = $self->_request( 'GET', $url );
    return VMware::vCloudDirector::Object->new(
        hash => $self->_decode_xml_response($response),
        api  => $self
    );
}

method PUT ($url, $xml_hash) {
    my $content = is_plain_hashref($xml_hash) ? $self->_encode_xml_content($xml_hash) : $xml_hash;
    my $response = $self->_request( 'PUT', $url );
    return VMware::vCloudDirector::Object->new(
        hash => $self->_decode_xml_response($response),
        api  => $self
    );
}

method POST ($url, $xml_hash) {
    my $content = is_plain_hashref($xml_hash) ? $self->_encode_xml_content($xml_hash) : $xml_hash;
    my $response = $self->_request( 'POST', $url );
    return VMware::vCloudDirector::Object->new(
        hash => $self->_decode_xml_response($response),
        api  => $self
    );
}

method DELETE ($url) {
    my $response = $self->_request( 'DELETE', $url );
    return VMware::vCloudDirector::Object->new(
        hash => $self->_decode_xml_response($response),
        api  => $self
    );
}

# ------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;

1;