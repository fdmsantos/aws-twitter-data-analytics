package main

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/aws/aws-sdk-go/aws/credentials"
	"github.com/aws/aws-sdk-go/aws/credentials/stscreds"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/firehose"
	"github.com/g8rswimmer/go-twitter/v2"
)

type authorize struct {
	Token string
}

func (a authorize) Add(req *http.Request) {
	req.Header.Add("Authorization", fmt.Sprintf("Bearer %s", a.Token))
}

func TwitterCreateNbaRule(client *twitter.Client) {
	rule := "nba"
	tag := "nba tweets"

	fmt.Println("Callout to tweet search stream add rule callout")

	streamRule := twitter.TweetSearchStreamRule{
		Value: rule,
		Tag:   tag,
	}

	searchStreamRules, err := client.TweetSearchStreamAddRule(context.Background(), []twitter.TweetSearchStreamRule{streamRule}, false)
	if err != nil {
		log.Panicf("tweet search stream add rule callout error: %v", err)
	}

	enc, err := json.MarshalIndent(searchStreamRules, "", "    ")
	if err != nil {
		log.Panic(err)
	}
	fmt.Println(string(enc))
}

func main() {
	token := os.Getenv("TWITTER_TOKEN")
	client := &twitter.Client{
		Authorizer: authorize{
			Token: token,
		},
		Client: http.DefaultClient,
		Host:   "https://api.twitter.com",
	}

	TwitterCreateNbaRule(client)

	opts := twitter.TweetSearchStreamOpts{
		Expansions: []twitter.Expansion{
			"entities.mentions.username",
			"author_id", "geo.place_id", "in_reply_to_user_id", "referenced_tweets.id", "referenced_tweets.id.author_id",
		},
		TweetFields: []twitter.TweetField{
			"context_annotations",
			"author_id",
			"conversation_id",
			"created_at",
			"entities", "geo", "in_reply_to_user_id", "lang", "possibly_sensitive", "referenced_tweets", "source",
		},
		UserFields: []twitter.UserField{
			"name",
			"location",
			"description", "entities", "id", "username",
		},
		PlaceFields: []twitter.PlaceField{
			"country",
			"country_code",
			"full_name",
			"geo",
			"name",
			"id", "place_type",
		},
	}

	fmt.Println("Callout to tweet search stream callout")

	tweetStream, err := client.TweetSearchStream(context.Background(), opts)
	if err != nil {
		log.Panicf("tweet sample callout error: %v", err)
	}

	var sess *session.Session
	if val, present := os.LookupEnv("ENV"); present && val == "LOCAL" {
		sess, _ = session.NewSession(&aws.Config{
			Credentials: credentials.NewSharedCredentials("", os.Getenv("AWS_PROFILE")),
		})

		creds := stscreds.NewCredentials(sess, os.Getenv("AWS_ASSUME_ROLE"))
		sess.Config.Credentials = creds
	} else {
		sess = session.Must(session.NewSession())
	}

	firehoseService := firehose.New(sess, aws.NewConfig().WithRegion("eu-west-1"))
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM, syscall.SIGKILL)
	func() {
		defer tweetStream.Close()
		for {
			select {
			case <-ch:
				fmt.Println("closing")
				return
			case tm := <-tweetStream.Tweets():
				tmb, err := json.Marshal(tm.Raw)
				if err != nil {
					fmt.Printf("error decoding tweet message %v", err)
				}

				fmt.Println("tweet")
				if _, err := firehoseService.PutRecord(&firehose.PutRecordInput{
					DeliveryStreamName: aws.String(os.Getenv("KINESIS_FIREHOSE_NAME")),
					Record: &firehose.Record{
						Data: tmb,
					},
				}); err != nil {
					fmt.Printf("error sending tweet to firehose %v", err)
				}
				fmt.Println("Sending Related Tweets..")
				for _, tweet := range tm.Raw.Includes.Tweets {
					tweetb, err := json.Marshal(tweet)
					if err != nil {
						fmt.Printf("error decoding tweet message %v", err)
					}
					if _, err := firehoseService.PutRecord(&firehose.PutRecordInput{
						DeliveryStreamName: aws.String(os.Getenv("KINESIS_FIREHOSE_NAME")),
						Record: &firehose.Record{
							Data: tweetb,
						},
					}); err != nil {
						fmt.Printf("error sending tweet to firehose %v", err)
					}
				}
			default:
			}
			if tweetStream.Connection() == false {
				fmt.Println("connection lost")
				return
			}
		}
	}()
}
