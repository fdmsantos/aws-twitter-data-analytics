package nbaTamperingFlink;

import software.amazon.awssdk.enhanced.dynamodb.mapper.annotations.DynamoDbBean;
import software.amazon.awssdk.enhanced.dynamodb.mapper.annotations.DynamoDbPartitionKey;
import software.amazon.awssdk.enhanced.dynamodb.mapper.annotations.DynamoDbSecondaryPartitionKey;

@DynamoDbBean
public class Player {
    private String account;
    private String name;
    private String team;

    @DynamoDbPartitionKey
    public String getAccount() {
        return this.account;
    }
    public void setAccount(String account) {
        this.account = account;
    }

    @DynamoDbSecondaryPartitionKey(indexNames = "PlayerNameIndex" )
    public String getName() {
        return this.name;
    }
    public void setName(String name) {
        this.name = name;
    }


    public String getTeam() {
        return this.team;
    }
    public void setTeam(String team) {
        this.team = team;
    }
}
