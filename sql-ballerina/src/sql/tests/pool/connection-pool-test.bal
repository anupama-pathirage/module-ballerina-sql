// Copyright (c) 2019, WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
//
// WSO2 Inc. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied. See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/lang.'int;
import ballerina/runtime;
import ballerina/stringutils;
import ballerina/test;


string poolDB_1 = urlPrefix + "9002/pool1";
string poolDB_2 = urlPrefix + "9003/pool2";

public type Result record {
    int val;
};

string datasourceName = "org.hsqldb.jdbc.JDBCDataSource";
map<anydata> connectionPoolOptions = {
    "connectionTimeout": "1000"
};

@test:BeforeGroups {
	value: ["pool"]	
} 
function initPoolContainer() {
	initializeDockerContainer("sql-pool1", "pool1", "9002", "pool", "connection-pool-test-data.sql");
	initializeDockerContainer("sql-pool2", "pool2", "9003", "pool", "connection-pool-test-data.sql");
}

@test:AfterGroups {
	value: ["pool"]	
} 
function cleanPoolContainer() {
	cleanDockerContainer("sql-pool1");
	cleanDockerContainer("sql-pool2");
}

@test:Config {
    groups: ["pool"]
}
function testGlobalConnectionPoolSingleDestination() {
    drainGlobalPool(poolDB_1);
}

@test:Config {
    groups: ["pool"]
}
function testGlobalConnectionPoolsMultipleDestinations() {
    drainGlobalPool(poolDB_1);
    drainGlobalPool(poolDB_2);
}

@test:Config {
    groups: ["pool"]
}
function testGlobalConnectionPoolSingleDestinationConcurrent() {
    worker w1 returns [stream<record{}, error>, stream<record{}, error>]|error {
        return testGlobalConnectionPoolConcurrentHelper1(poolDB_1);
    }

    worker w2 returns [stream<record{}, error>, stream<record{}, error>]|error {
        return testGlobalConnectionPoolConcurrentHelper1(poolDB_1);
    }

    worker w3 returns [stream<record{}, error>, stream<record{}, error>]|error {
        return testGlobalConnectionPoolConcurrentHelper1(poolDB_1);
    }

    worker w4 returns [stream<record{}, error>, stream<record{}, error>]|error {
        return testGlobalConnectionPoolConcurrentHelper1(poolDB_1);
    }

    record {
        [stream<record{}, error>, stream<record{}, error>]|error w1;
        [stream<record{}, error>, stream<record{}, error>]|error w2;
        [stream<record{}, error>, stream<record{}, error>]|error w3;
        [stream<record{}, error>, stream<record{}, error>]|error w4;
    } results = wait {w1, w2, w3, w4};

    var result2 = testGlobalConnectionPoolConcurrentHelper2(poolDB_1);

    (int|error)[][] returnArray = [];
    // Connections will be released here as we fully consume the data in the following conversion function calls
    returnArray[0] = checkpanic getCombinedReturnValue(results.w1);
    returnArray[1] = checkpanic getCombinedReturnValue(results.w2);
    returnArray[2] = checkpanic getCombinedReturnValue(results.w3);
    returnArray[3] = checkpanic getCombinedReturnValue(results.w4);
    returnArray[4] = result2;

    // All 5 clients are supposed to use the same pool. Default maximum no of connections is 10.
    // Since each select operation hold up one connection each, the last select operation should
    // return an error
    int i = 0;
    while(i < 4) {
        test:assertEquals(returnArray[i], [1, 1]);
        i = i + 1;
    }
    validateConnectionTimeoutError(returnArray[4][2]);
}

@test:Config {
    groups: ["pool"]
}
function testLocalSharedConnectionPoolConfigSingleDestination() {
    ConnectionPool pool = {maxOpenConnections: 5};
    MockClient dbClient1 = checkpanic new (url = poolDB_1, user = user, password = password, connectionPool = pool, connectionPoolOptions = connectionPoolOptions);
    MockClient dbClient2 = checkpanic new (url = poolDB_1, user = user, password = password, connectionPool = pool, connectionPoolOptions = connectionPoolOptions);
    MockClient dbClient3 = checkpanic new (url = poolDB_1, user = user, password = password, connectionPool = pool, connectionPoolOptions = connectionPoolOptions);
    MockClient dbClient4 = checkpanic new (url = poolDB_1, user = user, password = password, connectionPool = pool, connectionPoolOptions = connectionPoolOptions);
    MockClient dbClient5 = checkpanic new (url = poolDB_1, user = user, password = password, connectionPool = pool, connectionPoolOptions = connectionPoolOptions);
    
    (stream<record{}, error>)[] resultArray = [];
    resultArray[0] = dbClient1->query("select count(*) as val from Customers where registrationID = 1", Result);
    resultArray[1] = dbClient2->query("select count(*) as val from Customers where registrationID = 1", Result);
    resultArray[2] = dbClient3->query("select count(*) as val from Customers where registrationID = 2", Result);
    resultArray[3] = dbClient4->query("select count(*) as val from Customers where registrationID = 1", Result);
    resultArray[4] = dbClient5->query("select count(*) as val from Customers where registrationID = 1", Result);
    resultArray[5] = dbClient5->query("select count(*) as val from Customers where registrationID = 2", Result);

    (int|error)[] returnArray = [];
    int i = 0;
    // Connections will be released here as we fully consume the data in the following conversion function calls
    foreach var x in resultArray {
        returnArray[i] = getReturnValue(x);
        i += 1;
    }

    checkpanic dbClient1.close();
    checkpanic dbClient2.close();
    checkpanic dbClient3.close();
    checkpanic dbClient4.close();
    checkpanic dbClient5.close();

    // All 5 clients are supposed to use the same pool created with the configurations given by the
    // custom pool options. Since each select operation holds up one connection each, the last select
    // operation should return an error
    i = 0;
    while(i < 5) {
        test:assertEquals(returnArray[i], 1);
        i = i + 1;
    }
    validateConnectionTimeoutError(returnArray[5]);
}

@test:Config {
    groups: ["pool"]
}
function testLocalSharedConnectionPoolConfigDifferentDbOptions() {
    ConnectionPool pool = {maxOpenConnections: 3};
    MockClient dbClient1 = checkpanic new (url = poolDB_1, user = user, password = password,
        datasourceName = datasourceName, options = {"loginTimeout": "2000"}, connectionPool = pool,
        connectionPoolOptions = connectionPoolOptions);
    MockClient dbClient2 = checkpanic new (url = poolDB_1, user = user, password = password,
        datasourceName = datasourceName, options = {"loginTimeout": "2000"}, connectionPool = pool,
        connectionPoolOptions = connectionPoolOptions);
    MockClient dbClient3 = checkpanic new (url = poolDB_1, user = user, password = password,
        datasourceName = datasourceName, options = {"loginTimeout": "2000"}, connectionPool = pool,
        connectionPoolOptions = connectionPoolOptions);
    MockClient dbClient4 = checkpanic new (url = poolDB_1, user = user, password = password,
        datasourceName = datasourceName, options = {"loginTimeout": "1000"}, connectionPool = pool,
        connectionPoolOptions = connectionPoolOptions);
    MockClient dbClient5 = checkpanic new (url = poolDB_1, user = user, password = password,
        datasourceName = datasourceName, options = {"loginTimeout": "1000"}, connectionPool = pool,
        connectionPoolOptions = connectionPoolOptions);
    MockClient dbClient6 = checkpanic new (url = poolDB_1, user = user, password = password,
        datasourceName = datasourceName, options = {"loginTimeout": "1000"}, connectionPool = pool,
        connectionPoolOptions = connectionPoolOptions);

    stream<record {} , error>[] resultArray = [];
    resultArray[0] = dbClient1->query("select count(*) as val from Customers where registrationID = 1", Result);
    resultArray[1] = dbClient2->query("select count(*) as val from Customers where registrationID = 1", Result);
    resultArray[2] = dbClient3->query("select count(*) as val from Customers where registrationID = 2", Result);
    resultArray[3] = dbClient3->query("select count(*) as val from Customers where registrationID = 1", Result);

    resultArray[4] = dbClient4->query("select count(*) as val from Customers where registrationID = 1", Result);
    resultArray[5] = dbClient5->query("select count(*) as val from Customers where registrationID = 2", Result);
    resultArray[6] = dbClient6->query("select count(*) as val from Customers where registrationID = 2", Result);
    resultArray[7] = dbClient6->query("select count(*) as val from Customers where registrationID = 1", Result);

    (int|error)[] returnArray = [];
    int i = 0;
    // Connections will be released here as we fully consume the data in the following conversion function calls
    foreach var x in resultArray {
        returnArray[i] = getReturnValue(x);
        i += 1;
    }

    checkpanic dbClient1.close();
    checkpanic dbClient2.close();
    checkpanic dbClient3.close();
    checkpanic dbClient4.close();
    checkpanic dbClient5.close();
    checkpanic dbClient6.close();

    // Since max pool size is 3, the last select function call going through each pool should fail.
    i = 0;
    while(i < 3) {
        test:assertEquals(returnArray[i], 1);
        test:assertEquals(returnArray[i + 4], 1);
        i = i + 1;
    }
    validateConnectionTimeoutError(returnArray[3]);
    validateConnectionTimeoutError(returnArray[7]);
    
}

@test:Config {
    groups: ["pool"]
}
function testLocalSharedConnectionPoolConfigMultipleDestinations() {
    ConnectionPool pool = {maxOpenConnections: 3};
    MockClient dbClient1 = checkpanic new (url = poolDB_1, user = user, password = password, connectionPool = pool, connectionPoolOptions = connectionPoolOptions);
    MockClient dbClient2 = checkpanic new (url = poolDB_1, user = user, password = password, connectionPool = pool, connectionPoolOptions = connectionPoolOptions);
    MockClient dbClient3 = checkpanic new (url = poolDB_1, user = user, password = password, connectionPool = pool, connectionPoolOptions = connectionPoolOptions);
    MockClient dbClient4 = checkpanic new (url = poolDB_2, user = user, password = password, connectionPool = pool, connectionPoolOptions = connectionPoolOptions);
    MockClient dbClient5 = checkpanic new (url = poolDB_2, user = user, password = password, connectionPool = pool, connectionPoolOptions = connectionPoolOptions);
    MockClient dbClient6 = checkpanic new (url = poolDB_2, user = user, password = password, connectionPool = pool, connectionPoolOptions = connectionPoolOptions);

    stream<record {} , error>[] resultArray = [];
    resultArray[0] = dbClient1->query("select count(*) as val from Customers where registrationID = 1", Result);
    resultArray[1] = dbClient2->query("select count(*) as val from Customers where registrationID = 1", Result);
    resultArray[2] = dbClient3->query("select count(*) as val from Customers where registrationID = 2", Result);
    resultArray[3] = dbClient3->query("select count(*) as val from Customers where registrationID = 1", Result);

    resultArray[4] = dbClient4->query("select count(*) as val from Customers where registrationID = 1", Result);
    resultArray[5] = dbClient5->query("select count(*) as val from Customers where registrationID = 2", Result);
    resultArray[6] = dbClient6->query("select count(*) as val from Customers where registrationID = 2", Result);
    resultArray[7] = dbClient6->query("select count(*) as val from Customers where registrationID = 1", Result);

    (int|error)[] returnArray = [];
    int i = 0;
    // Connections will be released here as we fully consume the data in the following conversion function calls
    foreach var x in resultArray {
        returnArray[i] = getReturnValue(x);
        i += 1;
    }

    checkpanic dbClient1.close();
    checkpanic dbClient2.close();
    checkpanic dbClient3.close();
    checkpanic dbClient4.close();
    checkpanic dbClient5.close();
    checkpanic dbClient6.close();

    // Since max pool size is 3, the last select function call going through each pool should fail.
    i = 0;
    while(i < 3) {
        test:assertEquals(returnArray[i], 1);
        test:assertEquals(returnArray[i + 4], 1);
        i = i + 1;
    }
    validateConnectionTimeoutError(returnArray[3]);
    validateConnectionTimeoutError(returnArray[7]);
}

@test:Config {
    groups: ["pool"]
}
function testLocalSharedConnectionPoolCreateClientAfterShutdown() {
    ConnectionPool pool = {maxOpenConnections: 2};
    MockClient dbClient1 = checkpanic new (url = poolDB_1, user = user, password = password, connectionPoolOptions = connectionPoolOptions, connectionPool = pool);
    MockClient dbClient2 = checkpanic new (url = poolDB_1, user = user, password = password, connectionPoolOptions = connectionPoolOptions, connectionPool = pool);

    var dt1 = dbClient1->query("SELECT count(*) as val from Customers where registrationID = 1", Result);
    var dt2 = dbClient2->query("SELECT count(*) as val from Customers where registrationID = 1", Result);
    int|error result1 = getReturnValue(dt1);
    int|error result2 = getReturnValue(dt2);

    // Since both clients are stopped the pool is supposed to shutdown.
    checkpanic dbClient1.close();
    checkpanic dbClient2.close();

    // This call should return an error as pool is shutdown
    var dt3 = dbClient1->query("SELECT count(*) as val from Customers where registrationID = 1", Result);
    int|error result3 = getReturnValue(dt3);

    // Now a new pool should be created
    MockClient dbClient3 = checkpanic new (url = poolDB_1, user = user, password = password, connectionPoolOptions = connectionPoolOptions, connectionPool = pool);

    // This call should be successful
    var dt4 = dbClient3->query("SELECT count(*) as val from Customers where registrationID = 1", Result);
    int|error result4 = getReturnValue(dt4);

    checkpanic dbClient3.close();

    test:assertEquals(result1, 1);
    test:assertEquals(result2, 1);
    validateApplicationError(result3);
    test:assertEquals(result4, 1);
}

ConnectionPool pool1 = {maxOpenConnections: 2};

@test:Config {
    groups: ["pool"]
}
function testLocalSharedConnectionPoolStopInitInterleave() {
    worker w1 returns error? {
        check testLocalSharedConnectionPoolStopInitInterleaveHelper1(poolDB_1);
    }
    worker w2 returns int|error {
        return testLocalSharedConnectionPoolStopInitInterleaveHelper2(poolDB_1);
    }

    checkpanic wait w1;
    int|error result = wait w2;
    test:assertEquals(result, 1);
}

function testLocalSharedConnectionPoolStopInitInterleaveHelper1(string url)
returns error? {
    MockClient dbClient = check new (url = url, user = user, password = password, connectionPool = pool1,
        connectionPoolOptions = connectionPoolOptions);
    runtime:sleep(10);
    check dbClient.close();
}

function testLocalSharedConnectionPoolStopInitInterleaveHelper2(string url)
returns @tainted int|error {
    runtime:sleep(10);
    MockClient dbClient = check new (url = url, user = user, password = password, connectionPool = pool1,
        connectionPoolOptions = connectionPoolOptions);
    var dt = dbClient->query("SELECT COUNT(*) as val from Customers where registrationID = 1", Result);
    int|error count = getReturnValue(dt);
    check dbClient.close();
    return count;
}

@test:Config {
    groups: ["pool"]
}
function testShutDownUnsharedLocalConnectionPool() {
    ConnectionPool pool = {maxOpenConnections: 2};
    MockClient dbClient = checkpanic new (url = poolDB_1, user = user, password = password, connectionPool = pool, connectionPoolOptions = connectionPoolOptions);

    var result = dbClient->query("select count(*) as val from Customers where registrationID = 1", Result);
    int|error retVal1 = getReturnValue(result);
    // Pool should be shutdown as the only client using it is stopped.
    checkpanic dbClient.close();
    // This should result in an error return.
    var resultAfterPoolShutDown = dbClient->query("select count(*) as val from Customers where registrationID = 1",
        Result);
    int|error retVal2 = getReturnValue(resultAfterPoolShutDown);

    test:assertEquals(retVal1, 1);
    validateApplicationError(retVal2);
}

@test:Config {
    groups: ["pool"]
}
function testShutDownSharedConnectionPool() {
    ConnectionPool pool = {maxOpenConnections: 1};
    MockClient dbClient1 = checkpanic new (url = poolDB_1, user = user, password = password, connectionPoolOptions = connectionPoolOptions, connectionPool = pool);
    MockClient dbClient2 = checkpanic new (url = poolDB_1, user = user, password = password, connectionPoolOptions = connectionPoolOptions, connectionPool = pool);

    var result1 = dbClient1->query("select count(*) as val from Customers where registrationID = 1", Result);
    int|error retVal1 = getReturnValue(result1);

    var result2 = dbClient2->query("select count(*) as val from Customers where registrationID = 2", Result);
    int|error retVal2 = getReturnValue(result2);

    // Only one client is closed so pool should not shutdown.
    checkpanic dbClient1.close();

    // This should be successful as pool is still up.
    var result3 = dbClient2->query("select count(*) as val from Customers where registrationID = 2", Result);
    int|error retVal3 = getReturnValue(result3);

    // This should fail because, even though the pool is up, this client was stopped
    var result4 = dbClient1->query("select count(*) as val from Customers where registrationID = 2", Result);
    int|error retVal4 = getReturnValue(result4);

    // Now pool should be shutdown as the only remaining client is stopped.
    checkpanic dbClient2.close();

    // This should fail because this client is stopped.
    var result5 = dbClient2->query("select count(*) as val from Customers where registrationID = 2", Result);
    int|error retVal5 = getReturnValue(result4);

    test:assertEquals(retVal1, 1);
    test:assertEquals(retVal2, 1);
    test:assertEquals(retVal3, 1);
    validateApplicationError(retVal4);
    validateApplicationError(retVal5);
}

@test:Config {
    groups: ["pool"]
}
function testShutDownPoolCorrespondingToASharedPoolConfig() {
    ConnectionPool pool = {maxOpenConnections: 1};
    MockClient dbClient1 = checkpanic new (url = poolDB_1, user = user, password = password, connectionPool = pool, connectionPoolOptions = connectionPoolOptions);
    MockClient dbClient2 = checkpanic new (url = poolDB_1, user = user, password = password, connectionPool = pool, connectionPoolOptions = connectionPoolOptions);

    var result1 = dbClient1->query("select count(*) as val from Customers where registrationID = 1", Result);
    int|error retVal1 = getReturnValue(result1);

    var result2 = dbClient2->query("select count(*) as val from Customers where registrationID = 2", Result);
    int|error retVal2 = getReturnValue(result2);

    // This should result in stopping the pool used by this client as it was the only client using that pool.
    checkpanic dbClient1.close();

    // This should be successful as the pool belonging to this client is up.
    var result3 = dbClient2->query("select count(*) as val from Customers where registrationID = 2", Result);
    int|error retVal3 = getReturnValue(result3);

    // This should fail because this client was stopped.
    var result4 = dbClient1->query("select count(*) as val from Customers where registrationID = 2", Result);
    int|error retVal4 = getReturnValue(result4);

    checkpanic dbClient2.close();

    test:assertEquals(retVal1, 1);
    test:assertEquals(retVal2, 1);
    test:assertEquals(retVal3, 1);
    validateApplicationError(retVal4);
}

@test:Config {
    groups: ["pool"]
}
function testStopClientUsingGlobalPool() {
    // This client doesn't have pool config specified therefore, global pool will be used.
    MockClient dbClient = checkpanic new (url = poolDB_1, user = user, password = password, connectionPoolOptions = connectionPoolOptions);

    var result1 = dbClient->query("select count(*) as val from Customers where registrationID = 1", Result);
    int|error retVal1 = getReturnValue(result1);

    // This will merely stop this client and will not have any effect on the pool because it is the global pool.
    checkpanic dbClient.close();

    // This should fail because this client was stopped, even though the pool is up.
    var result2 = dbClient->query("select count(*) as val from Customers where registrationID = 1", Result);
    int|error retVal2 = getReturnValue(result2);

    test:assertEquals(retVal1, 1);
    validateApplicationError(retVal2);
}

@test:Config {
    groups: ["pool"]
}
function testLocalConnectionPoolShutDown() {
    int|error count1 = getOpenConnectionCount(poolDB_1);
    int|error count2 = getOpenConnectionCount(poolDB_2);
    test:assertEquals(count1, count2);
}

public type Variable record {
    string value;
    string variable_name;
};

function getOpenConnectionCount(string url) returns @tainted (int|error) {
    MockClient dbClient = check new (url = url, user = user, password = password, connectionPool = {maxOpenConnections: 1}, connectionPoolOptions = connectionPoolOptions);
    var dt = dbClient->query("show status where `variable_name` = 'Threads_connected'", Variable);
    int|error count = getIntVariableValue(dt);
    check dbClient.close();
    return count;
}

function testGlobalConnectionPoolConcurrentHelper1(string url) returns
    @tainted [stream<record{}, error>, stream<record{}, error>]|error {
    MockClient dbClient = check new (url = url, user = user, password = password, connectionPoolOptions = connectionPoolOptions);
    var dt1 = dbClient->query("select count(*) as val from Customers where registrationID = 1", Result);
    var dt2 = dbClient->query("select count(*) as val from Customers where registrationID = 2", Result);
    return [dt1, dt2];
}

function testGlobalConnectionPoolConcurrentHelper2(string url) returns @tainted (int|error)[] {
    MockClient dbClient = checkpanic new (url = url, user = user, password = password, connectionPoolOptions = connectionPoolOptions);
    (int|error)[] returnArray = [];
    var dt1 = dbClient->query("select count(*) as val from Customers where registrationID = 1", Result);
    var dt2 = dbClient->query("select count(*) as val from Customers where registrationID = 2", Result);
    var dt3 = dbClient->query("select count(*) as val from Customers where registrationID = 1", Result);
    // Connections will be released here as we fully consume the data in the following conversion function calls
    returnArray[0] = getReturnValue(dt1);
    returnArray[1] = getReturnValue(dt2);
    returnArray[2] = getReturnValue(dt3);

    return returnArray;
}

function getCombinedReturnValue([stream<record{}, error>, stream<record{}, error>]|error queryResult) returns
 (int|error)[]|error {
    if (queryResult is error) {
        return queryResult;
    } else {
        stream<record{}, error> x;
        stream<record{}, error> y;
        [x, y] = queryResult;
        (int|error)[] returnArray = [];
        returnArray[0] = getReturnValue(x);
        returnArray[1] = getReturnValue(y);
        return returnArray;
    }
}

function getIntVariableValue(stream<record{}, error> queryResult) returns int|error {
    int count = -1;
    record {|record {} value;|}? data = check queryResult.next();
    if (data is record {|record {} value;|}) {
        record {} variable = data.value;
        if (variable is Variable) {
            return 'int:fromString(variable.value);
        }
    }
    check queryResult.close();
    return count;
}


function drainGlobalPool(string url) {
    MockClient dbClient1 = checkpanic new (url = url, user = user, password = password, connectionPoolOptions = connectionPoolOptions);
    MockClient dbClient2 = checkpanic new (url = url, user = user, password = password, connectionPoolOptions = connectionPoolOptions);
    MockClient dbClient3 = checkpanic new (url = url, user = user, password = password, connectionPoolOptions = connectionPoolOptions);
    MockClient dbClient4 = checkpanic new (url = url, user = user, password = password, connectionPoolOptions = connectionPoolOptions);
    MockClient dbClient5 = checkpanic new (url = url, user = user, password = password, connectionPoolOptions = connectionPoolOptions);

    stream<record{}, error>[] resultArray = [];

    resultArray[0] = dbClient1->query("select count(*) as val from Customers where registrationID = 1", Result);
    resultArray[1] = dbClient1->query("select count(*) as val from Customers where registrationID = 2", Result);

    resultArray[2] = dbClient2->query("select count(*) as val from Customers where registrationID = 1", Result);
    resultArray[3] = dbClient2->query("select count(*) as val from Customers where registrationID = 1", Result);

    resultArray[4] = dbClient3->query("select count(*) as val from Customers where registrationID = 2", Result);
    resultArray[5] = dbClient3->query("select count(*) as val from Customers where registrationID = 2", Result);

    resultArray[6] = dbClient4->query("select count(*) as val from Customers where registrationID = 1", Result);
    resultArray[7] = dbClient4->query("select count(*) as val from Customers where registrationID = 1", Result);

    resultArray[8] = dbClient5->query("select count(*) as val from Customers where registrationID = 1", Result);
    resultArray[9] = dbClient5->query("select count(*) as val from Customers where registrationID = 1", Result);

    resultArray[10] = dbClient5->query("select count(*) as val from Customers where registrationID = 1", Result);

    (int|error)[] returnArray = [];
    int i = 0;
    // Connections will be released here as we fully consume the data in the following conversion function calls
    foreach var x in resultArray {
        returnArray[i] = getReturnValue(x);

        i += 1;
    }
    // All 5 clients are supposed to use the same pool. Default maximum no of connections is 10.
    // Since each select operation hold up one connection each, the last select operation should
    // return an error
    i = 0;
    while(i < 10) {
        test:assertEquals(returnArray[i], 1);
        i = i + 1;
    }
    validateConnectionTimeoutError(returnArray[10]);
}

function getReturnValue(stream<record{}, error> queryResult) returns int|error {
    int count = -1;
    record {|record {} value;|}? data = check queryResult.next();
    if (data is record {|record {} value;|}) {
        record {} value = data.value;
        if (value is Result) {
            count = value.val;
        }
    }
    check queryResult.close();
    return count;
}

function validateApplicationError(int|error dbError) {
    test:assertTrue(dbError is error);
    ApplicationError sqlError = <ApplicationError> dbError;
    test:assertTrue(stringutils:contains(sqlError.message(), "Client is already closed"), sqlError.message());
}

function validateConnectionTimeoutError(int|error dbError) {
    test:assertTrue(dbError is error);
    DatabaseError sqlError = <DatabaseError> dbError;
    test:assertTrue(stringutils:contains(sqlError.message(), "request timed out after"), sqlError.message());
}