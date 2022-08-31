package nbaTamperingFlink;

public class Tweet {
    private Long eventTime;
    private Player sourcePlayer;
    private Player destinationPlayer;

    public Tweet(Long eventTime,Player sourcePlayer, Player destinationPlayer) {
        this.eventTime = eventTime;
        this.sourcePlayer = sourcePlayer;
        this.destinationPlayer = destinationPlayer;
    }

    public String toString(){
        return sourcePlayer.getName()+" "+destinationPlayer.getName();
    }

    public Long getEventTime(){
        return eventTime;
    }

    public Player getSourcePlayer() {
        return sourcePlayer;
    }

    public Player getDestinationPlayer() {
        return destinationPlayer;
    }

}
