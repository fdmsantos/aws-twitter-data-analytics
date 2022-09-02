package nbaTamperingFlink;

public class Tweet {
    private Player sourcePlayer;
    private Player destinationPlayer;

    public Tweet(Player sourcePlayer, Player destinationPlayer) {
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
}
