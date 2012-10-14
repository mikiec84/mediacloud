#!/usr/bin/env perl

# Run through the controversy stories, trying to assign better date guesses

use strict;

BEGIN
{
    use FindBin;
    use lib "$FindBin::Bin/../lib";
}

use Data::Dumper;
use DateTime;
use Date::Parse;
use HTML::TreeBuilder::XPath;
use LWP::UserAgent;

use MediaWords::DB;

# each of the test dates in the $_date_guess_functions should resolve to this date
my $_test_epoch_date = 1326819600;

# threshhold of number of days a soft guess date can be off from the existing
# story date without dropping the guess
my $_soft_date_threshhold = 14;

# only use the date from these guessing functions if the date is within $_soft_date_threshhold days 
# of the existing date for the story
my $_date_guess_functions = 
    [ 
        { function => \&guess_by_dc_date_issued, test => '<meta name="DC.date.issued" content="2012-01-17T12:00:00-05:00" />' },
        { function => \&guess_by_dc_created, test => '<li property="dc:date dc:created" content="2012-01-17T12:00:00-05:00" datatype="xsd:dateTime" class="created">January 17, 2012</li>' },
        { function => \&guess_by_meta_publish_date, text => '<meta name="item-publish-date" content="Tue, 17 Jan 2012 12:00:00 EST" />' },
        { function => \&guess_by_storydate, test => '<p class="storydate">Tue, Jan 17th 2012</p>' },
        { function => \&guess_by_datatime, test => '<span class="date" data-time="1326819600">Jan 17, 2012 12:00 pm EST</span>' },
        { function => \&guess_by_datetime_pubdate, test => '<time datetime="2012-01-17" pubdate>Jan 17, 2012 12:00 pm EST</time>' },
        { function => \&guess_by_url_and_date_text },
        { function => \&guess_by_url },
        { function => \&guess_by_class_date, test => '<p class="date">Jan 17, 2012</p>' },
        { function => \&guess_by_date_text, test => '<p>foo bar</p><p class="dateline>published on Jan 17th, 2012, 12:00 PM EST' },
    ];

# return the first in a list of nodes matching the xpath pattern
sub find_first_node
{
    my ( $tree, $xpath ) = @_;

    my @nodes = $tree->findnodes( $xpath );

    my $node = pop @nodes;

    return $node;
}
# <meta name="DC.date.issued" content="2011-12-16T13:56:00-08:00" />
sub guess_by_dc_date_issued
{
    my ( $story, $html, $xpath ) = @_;
    
    if ( my $node = find_first_node( $xpath, '//meta[@name="DC.date.issued"]' ) )
    {
        return $node->attr( 'content' );
    }    
}

# <li property="dc:date dc:created" content="2012-01-17T05:51:44-07:00" datatype="xsd:dateTime" class="created">January 17, 2012</li>
sub guess_by_dc_created
{
    my ( $story, $html, $xpath ) = @_;
    
    if ( my $node = find_first_node( $xpath,  '//li[@property="dc:date dc:created"]' ) )
    {
        return $node->attr( 'content' );
    }    
}

# <meta name="item-publish-date" content="Wed, 28 Dec 2011 17:39:00 GMT" />
sub guess_by_meta_publish_date
{
    my ( $story, $html, $xpath ) = @_;
    
    if ( my $node = find_first_node( $xpath,  '//meta[@name="item-publish-date"]' ) )
    {
        return $node->attr( 'content' );
    }    
}

# <p class="storydate">Tue, Dec 6th 2011 7:28am</p>
sub guess_by_storydate
{
    my ( $story, $html, $xpath ) = @_;
    
    if ( my $node = find_first_node( $xpath,  '//p[@class="storydate"]' ) )
    {
        return $node->as_text;
    }    
}

# <span class="date" data-time="1326839460">Jan 17, 2012 10:31 pm UTC</span>
sub guess_by_datatime
{
    my ( $story, $html, $xpath ) = @_;

    if ( my $node = find_first_node( $xpath,  '//span[@class="date" and @data-time]' ) )
    {
        return $node->attr( 'data-time' );
    }    
}

# <time datetime="2012-06-06" pubdate="foo" />
sub guess_by_datetime_pubdate
{
    my ( $story, $html, $xpath ) = @_;

    if ( my $node = find_first_node( $xpath,  '//time[@datetime and @pubdate]' ) )
    {
        return $node->attr( 'datetime' );
    }    
}

# return true if the args are valid date arguments.  assume a date has to be between 2000 and 2020.
sub validate_date_parts
{
    my ( $year, $month, $day ) = @_;
    
    return 0 if ( ( $year < 2000 ) || ( $year > 2020 ) );
    
    return Date::Parse::str2time( "$year-$month-$day 12:00 PM", 'EST' );
}

# look for a date in the story url
sub guess_by_url
{
    my ( $story, $html, $xpath ) = @_;
    
    if ( ( $story->{ url } =~ m~(20\d\d)/(\d\d)/(\d\d)~ ) || ( $story->{ redirect_url } =~ m~(20\d\d)/(\d\d)/(\d\d)~ ) )
    {
        my $date = validate_date_parts( $1, $2, $3 );
        return $date if ( $date );
    }

    if ( ( $story->{ url } =~ m~/(20\d\d)(\d\d)(\d\d)/~ ) || ( $story->{ redirect_url } =~ m~(20\d\d)(\d\d)(\d\d)~ ) )
    {
        return validate_date_parts( $1, $2, $3 );
    }
}

# look for any element with a class='date' attribute
sub guess_by_class_date
{
    my ( $story, $html, $xpath ) = @_;

    if ( my $node = find_first_node( $xpath,  '//*[@class="date"]' ) )
    {
        return $node->as_text;
    }    

}

# look for any month name followed by something that looks like a date
sub guess_by_date_text
{
    my ( $story, $html, $xpath ) = @_;
    
    my $month_names = [ qw/january february march april may june july august september october november december/ ];
    
    push( @{ $month_names }, map { substr( $_, 0, 3 ) } @{ $month_names } );
    
    my $month_names_pattern = join( '|', @{ $month_names } );
    
    #  January 17, 2012 2:31 PM EST
    if ( $html =~ /((?:$month_names_pattern)\s*\d\d?(?:st|th)?(?:,|\s+at)?\s+20\d\d(?:,?\s*\d\d?\:\d\d\s*[AP]M(?:\s+\w\wT)?)?)/i )
    {
        my $date_string = $1;
                
        return $date_string;
    }
}

# if guess_by_url returns a date, use guess_by_date_text if the days agree
sub guess_by_url_and_date_text
{
    my ( $story, $html, $xpath ) = @_;
    
    my $url_date = guess_by_url( $story, $html, $xpath );
    
    return if ( !$url_date );
    
    my $text_date = make_epoch_date( guess_by_date_text( $story, $html, $xpath ) );
    
    if ( ( $text_date > $url_date ) and ( ( $text_date - $url_date ) < 86400 ) ) 
    {
        return $text_date;
    }
    else {
        return $url_date;
    }
}

# get the html for the story.  while downloads are not available, redownload the story.
sub get_story_html
{
    my ( $db, $story ) = @_;
    
    my $url = $story->{ redirect_url } || $story->{ url };
    
    my $ua = LWP::UserAgent->new;
    
    my $response = $ua->get( $url );
    
    if ( $response->is_success )
    {
        return $response->decoded_content;
    }
    else {
        return undef;
    }   
}

# if the date is exactly midnight, round it to noon because noon is a better guess of the publication time
sub round_midnight_to_noon
{
    my ( $date ) = @_;
    
    my @t = localtime( $date );
    
    if ( !$t[ 0 ] && !$t[ 1 ] && !$t[ 2 ]  )
    {
        return $date + 12 * 3600;
    }
    else {
        return $date;
    }
}

# if the date is a number, assume it is an epoch date and return it; otherwise, parse
# it and return the epoch date
sub make_epoch_date
{
    my ( $date ) = @_;
    
    return $date if ( $date =~ /^\d+$/ );

    my $epoch = Date::Parse::str2time( $date, 'EST' );

    $epoch = round_midnight_to_noon( $epoch );

    # if we have to use a default timezone, deal with daylight savings
    if ( ( $date =~ /T$/ ) && ( my $is_daylight_savings = ( localtime( $date ) )[ 8 ] ) )
    {
        $epoch += 3600;
    }

    return $epoch
}

# get HTML::TreeBuilder::XPath object representing the html
sub get_xpath
{
    my ( $html ) = @_;
    
    my $xpath = HTML::TreeBuilder::XPath->new;
    $xpath->ignore_unknown( 0 );
    $xpath->parse_content( $html );

    return $xpath;
}

# guess the date for the story by cycling through the $_date_guess_functions one at a time.  return the date in epoch format.
sub guess_date
{
    my ( $db, $story ) = @_;
    
    my $html = get_story_html( $db, $story );
    
    return undef if ( !$html );
    
    my $xpath = get_xpath( $html );

    my $story_epoch_date = make_epoch_date( $story->{ publish_date } );

    for my $date_guess_function ( @{ $_date_guess_functions } )
    {
        if ( my $date = make_epoch_date( $date_guess_function->{ function }->( $story, $html, $xpath ) ) )
        {
            return $date if ( ( $date - $story_epoch_date ) < ( $_soft_date_threshhold * 86400 ) );
        }
    }

    return undef;
}

# guess the date for the story and update it in the db
sub fix_date
{
    my ( $db, $story ) = @_;
    
    my $date = guess_date( $db, $story );
        
    my $date_string;
    if ( $date )
    {
        $date_string = DateTime->from_epoch( epoch => $date )->datetime;
        $db->query( "update stories set publish_date =  ? where stories_id = ?", $date_string, $story->{ stories_id } );
    }
    else {
        $date_string = '(no guess)';
    }
  
    print "$story->{ url }\t$story->{ publish_date }\t$date_string\n";
    
}

# test each date parser
sub test_date_parsers
{
    my $i = 0;
     for my $date_guess_function ( @{ $_date_guess_functions } )    
     {
         if ( my $test = $date_guess_function->{ test } )
         {
             my $xpath = get_xpath( $test );
    
             my $story = { url => $test };
             my $date = make_epoch_date( $date_guess_function->{ function }->( $story, $test, $xpath ) );
             
             if ( $date ne $_test_epoch_date )
             {
                 die( "test $i [ $test ] failed: got date '$date' expected '$_test_epoch_date'" );
             }
         }
         
         $i++;
     }   
}

# get all sopa stories
sub get_controversy_stories
{
    my ( $db, $controversy ) = @_;
    
    my $cid = $controversy->{ controversies_id };
    
    my $stories = $db->query( 
        "select distinct s.*, cs.redirect_url, md5( ( s.stories_id + 1 )::text ) from stories s, controversy_stories cs " . 
        "  where s.stories_id = cs.stories_id and cs.controversies_id = ?" . 
        "    and s.stories_id in " . 
        "      ( ( select stories_id from controversy_links_cross_media where controversies_id = ? ) union " . 
        "        ( select ref_stories_id from controversy_links_cross_media where controversies_id = ? ) ) " .
        "    and s.stories_id > 88745132 " .
#        "  order by md5( ( s.stories_id + 1 )::text ) limit 100" 
        "  order by stories_id ",
        $cid, $cid, $cid )->hashes;
        
    return $stories;
}

sub main
{
    my ( $controversies_id ) = @ARGV;
    
    die( "usage: $0 < controversies_id >" ) unless ( $controversies_id );
    
    my $db = MediaWords::DB::connect_to_db;

    my $controversy = $db->find_by_id( 'controversies', $controversies_id ) ||
        die( "Unable to find controversy '$controversies_id'" );
    
    test_date_parsers();

    my $stories = get_controversy_stories( $db, $controversy );
    
    map { fix_date( $db, $_ ) } @{ $stories };
    
}

main();