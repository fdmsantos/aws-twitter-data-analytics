package nbaTamperingFlink;

import software.amazon.awssdk.core.util.SdkUserAgent;
import software.amazon.awssdk.regions.servicemetadata.StreamsDynamodbServiceMetadata;

import java.awt.event.WindowStateListener;
import java.time.Instant;

public class Tweet {
    private Long eventTime;
    private Player sourcePlayer;
    private Player destinationPlayer;

    public Tweet(Long eventTime, Player sourcePlayer, Player destinationPlayer) {
        this.eventTime = eventTime;
        this.sourcePlayer = sourcePlayer;
        this.destinationPlayer = destinationPlayer;
    }

    public String toString(){
        return sourcePlayer.getName()+" "+destinationPlayer.getName();
    }

    public Player getSourcePlayer() {
        return sourcePlayer;
    }

    public Player getDestinationPlayer() {
        return destinationPlayer;
    }

    public Long getEventTime() {
        return eventTime;
    }
}
