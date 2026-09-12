function databaseChanges(result) {
	return Number(result?.meta?.changes ?? result?.changes ?? 0);
}

export { databaseChanges };
